//
//  MicCapture.swift
//  MaryVoice
//
//  WHAT: AVAudioEngine input tap → AsyncStream of MicFrame.
//  IN:   VoicePipeline.start / WakeWordListener
//  OUT:  MicFrame (separate engine from Kokoro playback)
//  PIN:  Bind a device only when the user picked it. Default-follow binds nothing.
//

import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

public final class MicCapture: @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case noInput
        case alreadyStarted
        public var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input is available."
            case .alreadyStarted: return "Microphone capture is already running."
            }
        }
    }

    private static let log = Logger(subsystem: "MaryVoice", category: "MicCapture")

    /// Bounded start retries while a Bluetooth route is still settling.
    private static let startAttempts = 4
    private static let startRetryDelay: TimeInterval = 0.25

    /// Keep stopped graphs alive past CoreAudio I/O-unit retirement (measured crash).
    private static let engineRetirementQueue = DispatchQueue(
        label: "mary.mic.engine-retirement")
    private static let engineRetirementGrace: TimeInterval = 10

    /// Fresh engine per rebuild — toggling VP on a stopped engine leaves a stale format.
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var continuation: AsyncStream<MicFrame>.Continuation?
    private var activeGeneration: UInt64?
    private let lifecycleGate = MicCaptureLifecycleGate()
    private let voiceProcessing: Bool

    public private(set) var format: AVAudioFormat?
    /// Whether Apple voice processing (echo cancellation) actually engaged.
    public private(set) var echoCancellationActive = false
    /// The UID the tap is actually bound to; nil means the system default is
    /// in effect (none requested, or the requested device is absent).
    public private(set) var activeDeviceUID: String?

    /// The user's sticky preference. When the device disappears we fall back
    /// to the default but keep this, so the tap rebinds when it returns.
    private var requestedDeviceUID: String?
    /// Set when the preference is PRESENT but delivers no frames: resolve to
    /// the default instead, until a hardware event or an explicit re-pick.
    private var requestedSuppressed = false
    /// The device explicitly bound to the input unit, for rebuild idempotence.
    /// nil in default-follow, where nothing is bound at all.
    private var boundDeviceID: AudioDeviceID?
    /// The system default at the last start. Default-follow binds nothing,
    /// so this — not `boundDeviceID` — is how a default SWITCH is noticed.
    private var followedDefaultID: AudioDeviceID?
    /// Whether the live route is one that takes its time coming up. Decides
    /// how long a start is given before the watchdog calls it dead.
    private var activeRouteIsWireless = false
    /// When the running engine last started, for rebuild spacing.
    private var lastStartAt = Date.distantPast

    public init(voiceProcessing: Bool = true, deviceUID: String? = nil) {
        self.voiceProcessing = voiceProcessing
        self.requestedDeviceUID = deviceUID
    }

    // MARK: - Session lifecycle

    /// Start the tap. The returned stream ends when `stop()` is called.
    public func start() throws -> AsyncStream<MicFrame> {
        let (stream, continuation) = AsyncStream<MicFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        guard let generation = lifecycleGate.begin() else {
            continuation.finish()
            throw CaptureError.alreadyStarted
        }

        // Settling route ≠ missing mic. Bounded retry; genuine no-input still fails.
        do {
            try controlQueue.sync {
                guard self.continuation == nil else {
                    throw CaptureError.alreadyStarted
                }
                self.continuation = continuation
                self.activeGeneration = generation
                var attempt = 0
                while true {
                    do {
                        try configureAndStart(for: generation)
                        break
                    } catch {
                        guard lifecycleGate.allows(generation) else { throw error }
                        attempt += 1
                        guard attempt < Self.startAttempts else { throw error }
                        Self.log.notice(
                            "input not ready yet (attempt \(attempt)); waiting for the route to settle")
                        Thread.sleep(forTimeInterval: Self.startRetryDelay)
                    }
                }

                guard lifecycleGate.allows(generation) else {
                    throw CancellationError()
                }

                // Hardware plug/unplug. Generation-gated so a queued callback cannot revive a stopped graph.
                deviceMonitor = AudioDeviceMonitor(queue: controlQueue) { [weak self] in
                    guard let self, self.lifecycleGate.allows(generation),
                          self.activeGeneration == generation else { return }
                    self.requestedSuppressed = false
                    self.scheduleRebuild(for: generation)
                }
            }
        } catch {
            lifecycleGate.finish(generation)
            controlQueue.sync {
                if self.activeGeneration == generation {
                    self.pendingRebuild?.cancel()
                    self.pendingRebuild = nil
                    self.continuation = nil
                    self.activeGeneration = nil
                    self.deviceMonitor?.stop()
                    self.deviceMonitor = nil
                    self.tearDownCurrentEngine()
                }
            }
            continuation.finish()
            throw error
        }

        return stream
    }

    /// Close the generation, then detach continuation + graph on `controlQueue`.
    public func stop() {
        // Close the gate before waiting on the queue so an in-flight start will not publish.
        lifecycleGate.requestStop()
        let live = controlQueue.sync { () -> AsyncStream<MicFrame>.Continuation? in
            let live = continuation
            pendingRebuild?.cancel()
            pendingRebuild = nil
            continuation = nil
            activeGeneration = nil
            deviceMonitor?.stop()
            deviceMonitor = nil
            tearDownCurrentEngine()
            return live
        }
        live?.finish()
    }

    /// Settings device switch. nil = system default. Reuses the live continuation.
    public func setPreferredDevice(uid: String?) {
        controlQueue.async {
            // An explicit re-pick always retries, even a suppressed device.
            self.requestedSuppressed = false
            self.requestedDeviceUID = uid
            guard let generation = self.activeGeneration else { return }
            self.scheduleRebuild(for: generation)
        }
    }

    // MARK: - Configure (shared by start, rebuilds, canary fallback)

    /// Every (re)start on `controlQueue`. PIN: bind device after VP (it swaps the I/O unit).
    private func configureAndStart(for generation: UInt64) throws {
        guard lifecycleGate.allows(generation),
              activeGeneration == generation,
              let continuation else {
            throw CancellationError()
        }

        // A failed attempt and every rebuild must have detached its old graph
        // before reaching here. Keeping the new engine in the property from
        // the moment it exists lets every error path retire it safely.
        tearDownCurrentEngine()
        let newEngine = AVAudioEngine()
        engine = newEngine
        let input = newEngine.inputNode

        let (deviceID, deviceUID) = resolveDesiredDevice()

        // Echo-cancel so barge-in hears the user, not playback. Best-effort; skip wireless / canary-dead.
        let vpKey = Self.voiceProcessingKey(for: deviceID, uid: deviceUID)
        let wantVP = voiceProcessing
            && !Self.isWirelessRoute(deviceID)
            && !vpFailedDeviceKeys.contains(vpKey)
        if input.isVoiceProcessingEnabled != wantVP {
            do {
                try input.setVoiceProcessingEnabled(wantVP)
            } catch {
                Self.log.warning("voice processing toggle refused: \(error.localizedDescription)")
                vpFailedDeviceKeys.insert(vpKey)
            }
        }
        echoCancellationActive = input.isVoiceProcessingEnabled

        // Bind only an explicit pick. Default-follow must stay on CADefaultDeviceAggregate.
        if deviceUID != nil {
            bindInputDevice(deviceID, on: input)
            followedDefaultID = nil
        } else {
            boundDeviceID = nil
            followedDefaultID = deviceID
        }
        activeDeviceUID = deviceUID
        activeRouteIsWireless = Self.isWirelessRoute(deviceID)

        // Format after VP (it changes it). Tap is explicit mono at the node's rate.
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nodeFormat.sampleRate,
            channels: 1,
            interleaved: false) ?? nodeFormat
        format = tapFormat

        // A fresh device deserves a fresh canary attempt.
        zeroStreak = 0
        canaryTripped = false

        guard lifecycleGate.allows(generation) else {
            tearDownCurrentEngine()
            throw CancellationError()
        }

        installTap(
            on: newEngine,
            format: tapFormat,
            continuation: continuation,
            generation: generation)
        tapInstalled = true
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            // VP enable can succeed then start fails (-10875). Retry once without VP.
            let shouldRetryWithoutVP = input.isVoiceProcessingEnabled
                && lifecycleGate.allows(generation)
            tearDownCurrentEngine()
            guard shouldRetryWithoutVP else { throw error }
            Self.log.warning("engine start failed with voice processing (\(error.localizedDescription)); retrying without")
            vpFailedDeviceKeys.insert(vpKey)
            try configureAndStart(for: generation)
            return
        }

        // start() is not interruptible; drop the graph if stop closed the gate meanwhile.
        guard lifecycleGate.allows(generation) else {
            tearDownCurrentEngine()
            throw CancellationError()
        }

        // Default-input switches and format changes announce themselves per
        // engine instance; funnel into the same debounced rebuild path as
        // the HAL listener.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async {
                guard self.lifecycleGate.allows(generation),
                      self.activeGeneration == generation else { return }
                self.scheduleRebuild(for: generation)
            }
        }

        startGeneration += 1
        lastStartAt = Date()
        armFrameFlowWatchdog(for: generation)
    }

    /// Frame-flow watchdog. One recovery (fallback or drop VP), then wait for hardware.
    /// Generation-guarded so a blocked rebuild cannot judge a brand-new engine.
    private func armFrameFlowWatchdog(for lifecycleGeneration: UInt64) {
        let marker = framesObserved
        let engineStartGeneration = startGeneration
        // Wireless is slow, not dead. Longer grace; do not rebuild mid-settle.
        let grace = activeRouteIsWireless ? 6.0 : 2.5
        controlQueue.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self,
                  self.lifecycleGate.allows(lifecycleGeneration),
                  self.activeGeneration == lifecycleGeneration,
                  engineStartGeneration == self.startGeneration else { return }
            if self.framesObserved != marker {
                self.deadStartCount = 0
                return
            }
            self.deadStartCount += 1
            if self.requestedDeviceUID != nil, !self.requestedSuppressed {
                // Preference enumerates but delivers no frames — fall back until the next hardware event.
                self.requestedSuppressed = true
                Self.log.error("selected input delivers no frames; using system default until the next device event")
                self.performRebuild(force: true, for: lifecycleGeneration)
                return
            }

            if self.echoCancellationActive {
                let (deviceID, deviceUID) = self.resolveDesiredDevice()
                let key = Self.voiceProcessingKey(for: deviceID, uid: deviceUID)
                self.vpFailedDeviceKeys.insert(key)
                Self.log.error("voice-processed input delivers no frames; rebuilding once without voice processing")
                self.performRebuild(force: true, for: lifecycleGeneration)
                return
            }

            Self.log.error("engine running but no frames arrived; waiting for a route-change event")
        }
    }

    /// The device the tap SHOULD use right now: the requested UID when
    /// present, else the system default (with `nil` UID marking fallback).
    private func resolveDesiredDevice() -> (AudioDeviceID?, String?) {
        if let uid = requestedDeviceUID, !requestedSuppressed {
            if let id = AudioInputDeviceList.deviceID(forUID: uid) {
                return (id, uid)
            }
            Self.log.notice("preferred input \(uid, privacy: .public) absent; using system default")
        }
        return (AudioInputDeviceList.defaultInputDeviceID(), nil)
    }

    /// Bind a concrete device to the input unit. Binding failure is not
    /// fatal — the unit keeps whatever device it had (usually the default).
    private func bindInputDevice(_ deviceID: AudioDeviceID?, on input: AVAudioInputNode) {
        guard var deviceID, let unit = input.audioUnit else {
            boundDeviceID = nil
            return
        }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            boundDeviceID = deviceID
        } else {
            Self.log.error("input device bind failed (\(status)); keeping current device")
            boundDeviceID = nil
        }
    }

    // MARK: - Rebuild machinery (all on controlQueue)

    private let controlQueue = DispatchQueue(label: "mary.mic.control")
    private var pendingRebuild: DispatchWorkItem?
    private var rebuildFailures = 0
    private var deviceMonitor: AudioDeviceMonitor?
    private var configChangeObserver: NSObjectProtocol?

    /// Detach the graph, then quarantine it past CoreAudio's already-enqueued I/O callbacks.
    private func tearDownCurrentEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        guard let retiringEngine = engine else {
            tapInstalled = false
            return
        }
        if tapInstalled {
            retiringEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        retiringEngine.stop()
        startGeneration &+= 1
        echoCancellationActive = false
        engine = nil
        Self.retireEngine(retiringEngine)
    }

    private static func retireEngine(_ engine: AVAudioEngine) {
        engineRetirementQueue.asyncAfter(
            deadline: .now() + engineRetirementGrace
        ) {
            // The closure's strong capture is intentional. Do not replace it
            // with an autorelease pool or a weak collection.
            withExtendedLifetime(engine) {}
        }
    }

    /// Debounced: a device unplugging fires the HAL listener AND the engine
    /// notification (and our own restart fires the notification again) — one
    /// rebuild serves them all.
    private func scheduleRebuild(
        after delay: TimeInterval = 0.3,
        for generation: UInt64
    ) {
        guard lifecycleGate.allows(generation),
              activeGeneration == generation else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performRebuild(for: generation)
        }
        pendingRebuild = work
        controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performRebuild(force: Bool = false, for generation: UInt64) {
        pendingRebuild = nil
        guard lifecycleGate.allows(generation),
              activeGeneration == generation else { return }

        // Let a settling route settle. Coalesce HAL bursts into one rebuild.
        let settle = activeRouteIsWireless ? 2.0 : 0.5
        let sinceStart = Date().timeIntervalSince(lastStartAt)
        if !force, sinceStart < settle {
            scheduleRebuild(after: settle - sinceStart, for: generation)
            return
        }

        // Idempotence: match by UID for a requested device (IDs churn). ID only for default-follow.
        let (desiredID, desiredUID) = resolveDesiredDevice()
        let vpKey = Self.voiceProcessingKey(for: desiredID, uid: desiredUID)
        let wantVP = voiceProcessing
            && !Self.isWirelessRoute(desiredID)
            && !vpFailedDeviceKeys.contains(vpKey)
        let sameDevice = desiredUID != nil
            ? desiredUID == activeDeviceUID
            : activeDeviceUID == nil && followedDefaultID == desiredID
        if !force,
           engine?.isRunning == true,
           sameDevice,
           engine?.inputNode.isVoiceProcessingEnabled == wantVP {
            return
        }

        tearDownCurrentEngine()
        guard lifecycleGate.allows(generation),
              activeGeneration == generation else { return }
        do {
            try configureAndStart(for: generation)
            rebuildFailures = 0
            Self.log.info("mic tap rebuilt on \(self.activeDeviceUID ?? "system default", privacy: .public)")
        } catch {
            tearDownCurrentEngine()
            guard lifecycleGate.allows(generation),
                  activeGeneration == generation else { return }
            // Mid-transition the HAL can report a device with no usable
            // format yet. Retry briefly; a later hardware event re-arms this
            // path anyway.
            rebuildFailures += 1
            Self.log.error("mic rebuild failed (attempt \(self.rebuildFailures)): \(error.localizedDescription)")
            if rebuildFailures < 3 {
                scheduleRebuild(after: 0.5, for: generation)
            }
        }
    }

    // MARK: - Tap + dead-stream canary

    /// ~21 ms tap. Dead-stream canary (exact-zero VP) lives in `noteFrame`.
    private func installTap(
        on engine: AVAudioEngine,
        format tapFormat: AVAudioFormat,
        continuation: AsyncStream<MicFrame>.Continuation,
        generation: UInt64
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, self.lifecycleGate.allows(generation) else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))
            let duration = Double(frames) / tapFormat.sampleRate
            self.noteFrame(rms: rms, duration: duration, generation: generation)
            guard self.lifecycleGate.allows(generation) else { return }
            continuation.yield(MicFrame(buffer: buffer, rms: rms, duration: duration))
        }
    }

    private var zeroStreak: TimeInterval = 0
    private var canaryTripped = false
    /// Total frames the tap has ever delivered (controlQueue). The frame-flow
    /// watchdog compares before/after a start to detect a dead route.
    private var framesObserved: UInt64 = 0
    /// Consecutive starts that delivered no frames; reset by the first frame.
    private var deadStartCount = 0
    /// Bumped on every engine start; stale frame-flow watchdogs check it and
    /// stand down (controlQueue).
    private var startGeneration: UInt64 = 0
    /// Resolved-UID keys where VP failed or went silent. Never retried this session.
    private var vpFailedDeviceKeys: Set<String> = []

    private static func voiceProcessingKey(
        for deviceID: AudioDeviceID?, uid: String?
    ) -> String {
        uid ?? deviceID.flatMap(AudioInputDeviceList.uid(for:)) ?? "default"
    }

    /// Wireless: no VP, longer start grace. Continuity VP dies; AirPods VP forces HFP.
    private static func isWirelessRoute(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID else { return false }
        return AudioInputDeviceList.isContinuityCapture(deviceID)
            || AudioInputDeviceList.isBluetooth(deviceID)
    }

    private func noteFrame(
        rms: Float,
        duration: TimeInterval,
        generation: UInt64
    ) {
        controlQueue.async { [weak self] in
            guard let self,
                  self.lifecycleGate.allows(generation),
                  self.activeGeneration == generation else { return }
            self.framesObserved += 1
            self.deadStartCount = 0
            guard self.echoCancellationActive, !self.canaryTripped else { return }
            if rms == 0 {
                self.zeroStreak += duration
                if self.zeroStreak >= 1.5 {
                    self.canaryTripped = true
                    let (deviceID, deviceUID) = self.resolveDesiredDevice()
                    self.vpFailedDeviceKeys.insert(
                        Self.voiceProcessingKey(for: deviceID, uid: deviceUID))
                    Self.log.notice("voice processing dead-stream canary tripped; rebuilding without it")
                    self.pendingRebuild?.cancel()
                    self.pendingRebuild = nil
                    self.performRebuild(for: generation)
                }
            } else {
                self.zeroStreak = 0
            }
        }
    }
}
