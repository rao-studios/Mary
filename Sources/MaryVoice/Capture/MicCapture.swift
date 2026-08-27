//
//  MicCapture.swift
//  MaryVoice
//
//  How the user's voice enters the application: one AVAudioEngine input tap,
//  exposed as an AsyncStream of (buffer, rms) frames. Kokoro playback owns a
//  separate engine — capture and playback never share a graph.
//
//  The tap can follow a SPECIFIC input device (bound by UID — a Continuity
//  iPhone, a USB mic) or the system default. Devices come and go mid-session,
//  so every teardown/rebuild is serialized through one control queue and
//  reuses the same stream continuation: the pipeline never sees a device
//  change, only frames.
//
//  ONE RULE ABOVE ALL, AND IT IS PAID FOR IN CRASHES: never bind a specific
//  device unless the USER explicitly picked it. AVAudioEngine's default-follow
//  runs on a `CADefaultDeviceAggregate`; writing
//  `kAudioOutputUnitProperty_CurrentDevice` moves the AUHAL off it and the two
//  then ping-pong every couple of seconds (start → error 35 → stop → start),
//  which is the mic icon flickering without ever sustaining — and, when a
//  background feature does it automatically, a HAL-client SIGSEGV (measured
//  2026-08-15, crashed twice on 2026-08-17 when standby auto-picked the
//  built-in mic). `deviceUID` is for the Settings picker. Default-follow binds
//  NOTHING.
//
//  WIRELESS ROUTES ARE THE HARD CASE, and the reason this file is not fifty
//  lines. AirPods and Continuity iPhones do not appear atomically: the device
//  enumerates before it can deliver audio, arrives with a different sample
//  rate than the built-in mic, and re-registers under a fresh transient
//  AudioDeviceID on every grab. A capture that reads the format once at
//  start() and never listens again is why toggling the mic on and off until
//  it "takes" was ever necessary — the tap is now the thing that follows the
//  hardware, so the user does not have to.
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

    /// Attempts to bring the tap up at session start, and the pause between
    /// them — enough to cover a Bluetooth route mid-connection without
    /// leaving a mic-less machine hanging.
    private static let startAttempts = 4
    private static let startRetryDelay: TimeInterval = 0.25

    /// AVAudioEngine has no public "all AVAudioIOUnit callbacks retired"
    /// barrier. `stop()` and `removeTap` stop future work, but the CoreAudio
    /// I/O queue can still hold callbacks which retain neither the engine nor
    /// its nodes. Deallocating the graph at that point is the measured crash.
    /// Keep stopped graphs alive beyond the longest wireless-route settling
    /// window before allowing ARC to destroy their AudioUnits.
    private static let engineRetirementQueue = DispatchQueue(
        label: "mary.mic.engine-retirement")
    private static let engineRetirementGrace: TimeInterval = 10

    /// Recreated on every rebuild: toggling voice processing on a stopped
    /// engine leaves the input node reporting a STALE format, and the next
    /// installTap throws NSException "format mismatch" (reproduced live with
    /// a Continuity iPhone). A fresh engine is exactly the initial-start
    /// path, which is known-good.
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

        // A SETTLING ROUTE IS NOT A MISSING MICROPHONE. AirPods enumerate
        // before they can deliver audio, and for that window the HAL reports
        // the device with no usable format — `configureAndStart` throws
        // `.noInput`, the session refuses to start, and the only recourse the
        // user has is to toggle listening again until the timing happens to
        // line up. That toggling ritual is this retry. Bounded, because a
        // machine with genuinely no input must still say so.
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

                // The HAL side of the rebuild triggers: hardware
                // appearing/vanishing (the selected device unplugging while
                // a stalled engine says nothing). Capture the generation so
                // a callback already queued when stop begins cannot revive
                // the graph.
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

    /// Stop permission is revoked before waiting for the control queue, then
    /// the continuation and graph are detached inside that queue. Both halves
    /// matter: queued rebuilds see a closed generation immediately, and no
    /// teardown can overlap a graph mutation already executing on the queue.
    public func stop() {
        // This flag is intentionally closed BEFORE waiting for the control
        // queue. If configure/start is already running, every boundary it
        // crosses sees the stop intent and declines to publish the graph.
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

    /// Live device switch (Settings). nil reverts to the system default.
    /// The rebuild reuses the existing continuation, so downstream VAD/STT
    /// never notice beyond at most one dropped utterance.
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

    /// Every engine (re)start goes through here, on `controlQueue`. Ordering
    /// is load-bearing: `setVoiceProcessingEnabled` swaps the underlying I/O
    /// unit and DISCARDS a previously set current-device property, so the
    /// device must be bound after it — and the node format read after both.
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

        // Full-duplex listening picks up Mary's own speaker output; Apple's
        // voice processing cancels the echo so barge-in detection hears the
        // USER, not Kokoro. Best-effort: some devices/routes refuse — fall
        // back to the plain tap and let the boosted RMS threshold guard alone.
        // A device the canary already proved dead under VP never gets it
        // again this session, and the routes listed in
        // `isWirelessRoute` never get it at all.
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

        // BIND ONLY WHAT WAS ASKED FOR. Writing
        // `kAudioOutputUnitProperty_CurrentDevice` moves the AUHAL off the
        // `CADefaultDeviceAggregate` that AVAudioEngine builds for
        // default-follow and onto the raw device — and for AirPods that is
        // actively destructive.
        //
        // MEASURED 2026-08-15: binding the AirPods directly while they were
        // merely the system default produced fourteen seconds of
        //
        //     Started Input {74-77-86-…:input} → _StartIO: Start failed,
        //     StartAndWaitForState returned error 35 → Stopped →
        //     HALB_IOThread::_Start: there already is a thread →
        //     Started Input {CADefaultDeviceAggregate-…} → SetPropertyData:
        //     call to the proxy failed, Error 2003332927 ('who?')
        //
        // ping-ponging between the two roughly every two seconds — the mic
        // icon appearing and vanishing in the menu bar, never sustaining,
        // and CoreAudio left with a leaked IO thread. The bind is what the
        // explicit picker needs; default-follow must not pay for it.
        if deviceUID != nil {
            bindInputDevice(deviceID, on: input)
            followedDefaultID = nil
        } else {
            boundDeviceID = nil
            followedDefaultID = deviceID
        }
        activeDeviceUID = deviceUID
        activeRouteIsWireless = Self.isWirelessRoute(deviceID)

        // Read the node format AFTER voice processing — it changes it
        // (measured live: 48 kHz becomes NINE channels). Downstream (VAD,
        // STT) expects mono, so the tap always requests an explicit mono
        // format at the node's rate; the engine converts.
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
            // Seen live (-10875): the voice-processing unit can fail to
            // INITIALIZE even though enabling it succeeded. A plain tap
            // beats a dead mic — retry once without VP (the key is now in
            // the failed set, so the recursion resolves wantVP to false).
            let shouldRetryWithoutVP = input.isVoiceProcessingEnabled
                && lifecycleGate.allows(generation)
            tearDownCurrentEngine()
            guard shouldRetryWithoutVP else { throw error }
            Self.log.warning("engine start failed with voice processing (\(error.localizedDescription)); retrying without")
            vpFailedDeviceKeys.insert(vpKey)
            try configureAndStart(for: generation)
            return
        }

        // `engine.start()` is synchronous but not interruptible. A concurrent
        // stop closes the gate before waiting for this queue; do not publish
        // an engine that crossed that stop boundary while starting.
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

    /// The zero-RMS canary sees frames that ARRIVE; a rebuilt engine can also
    /// claim to run while delivering nothing at all (observed live with a
    /// Continuity iPhone after a canary rebuild). A blind restart of the same
    /// route is deliberately NOT the remedy: repeated graph destruction while
    /// CoreAudio is still settling caused both route churn and the measured
    /// AVAudioIOUnit use-after-free. We permit one meaningful recovery — a
    /// selected-device fallback or disabling a dead voice-processing path —
    /// then wait for an actual hardware/configuration event.
    ///
    /// Generation-guarded: a rebuild can block the control queue for
    /// seconds, and a watchdog armed for an OLDER start would otherwise fire
    /// the moment the queue unblocks and judge the brand-new engine with no
    /// grace time. That exact cascade (four grabs in ~12 s) is what made a
    /// Continuity iPhone drop its session live. Each start only ever
    /// answers to the watchdog it armed.
    private func armFrameFlowWatchdog(for lifecycleGeneration: UInt64) {
        let marker = framesObserved
        let engineStartGeneration = startGeneration
        // A WIRELESS ROUTE IS SLOW, NOT DEAD. Opening the AirPods microphone
        // makes them renegotiate the Bluetooth profile — the output stream
        // drops and comes back as part of it — and that took whole seconds
        // when it was measured. Judging it at 2.5 s and rebuilding does not
        // rescue the start, it CANCELS one that was still in progress, and
        // the next attempt inherits a half-torn-down route. The budget below
        // is omitted for the same reason: on a wireless route, retrying the
        // same graph harder is the failure mode, not the fix.
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
                // Present but dead (a Continuity phone that dropped its
                // session still enumerates). A silent mic is the worst
                // outcome for a voice app — take the default until the
                // hardware changes state, then try the preference again.
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

    /// Detaches the live graph on `controlQueue`, then quarantines its object
    /// graph. The quarantine is an object-lifetime requirement, not a debounce:
    /// generation gates protect Mary callbacks, while this strong capture
    /// protects CoreAudio's own already-enqueued callbacks from a dangling
    /// AVAudioEngine/AVAudioNode target.
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

        // LET A SETTLING ROUTE SETTLE. A Bluetooth profile switch fires a
        // burst of HAL notifications while it happens — device list, default
        // input, engine configuration — and rebuilding on each one restarts
        // the very negotiation that was producing them. Anything that is not
        // the watchdog waits until the current start has had its quiet
        // window, and coalesces into one rebuild when it has.
        let settle = activeRouteIsWireless ? 2.0 : 0.5
        let sinceStart = Date().timeIntervalSince(lastStartAt)
        if !force, sinceStart < settle {
            scheduleRebuild(after: settle - sinceStart, for: generation)
            return
        }

        // Idempotence: our own engine restart echoes back as a configuration
        // change. When the running tap already matches the desired device and
        // VP state, there is nothing to do — this is what terminates the
        // notification → rebuild → notification cycle. (`force` is the
        // frame-flow watchdog's override: there everything LOOKS right and
        // the stream is dead anyway.)
        //
        // Matching is BY UID for a requested device: a Continuity iPhone —
        // and AirPods, measured since — re-registers with a fresh transient
        // AudioDeviceID on every grab, so comparing IDs makes each rebuild
        // invalidate itself, a ~2/s rebuild loop. The ID comparison remains
        // only for default-follow, where a default SWITCH must be noticed
        // and nothing else can tell us it happened.
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

    /// ~21 ms at 48 kHz — fine-grained enough for VAD, cheap enough to tap.
    /// Includes the dead-stream canary: if voice processing yields ~1.5s of
    /// EXACTLY zero audio (a known macOS failure mode), fall back to the
    /// plain tap so the mic never silently dies. A truly silent room still
    /// carries a nonzero noise floor on real hardware.
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
    /// Devices (by UID, "default" only when the HAL will not name the
    /// device) where voice processing was refused or produced a dead stream —
    /// never re-attempted this session, so a device-change rebuild can't
    /// ping-pong back into a tap the canary already proved dead.
    ///
    /// Keyed by the RESOLVED device's UID even when following the system
    /// default: a shared "default" key would let a failure on one device
    /// disable echo cancellation on the next one the user switches to.
    private var vpFailedDeviceKeys: Set<String> = []

    private static func voiceProcessingKey(
        for deviceID: AudioDeviceID?, uid: String?
    ) -> String {
        uid ?? deviceID.flatMap(AudioInputDeviceList.uid(for:)) ?? "default"
    }

    /// Routes that arrive over the air, which has two consequences here: no
    /// voice processing (below), and a start that legitimately takes seconds,
    /// so the frame-flow watchdog must not call one dead at 2.5 s.
    ///
    /// VOICE PROCESSING IS NEVER ATTEMPTED ON THESE rather than
    /// attempted-and-recovered. Both entries are measured, not assumed.
    ///
    /// CONTINUITY IPHONES: AUVoiceIO either starts dead (frames never arrive)
    /// or fails to initialize (-10875), and the resulting restart churn makes
    /// the phone drop the whole audio session — the "Audio Disconnected"
    /// banner, with the phone still showing itself as connected.
    ///
    /// BLUETOOTH (AIRPODS): enabling VP moves the headset onto the
    /// call/HFP profile, which is both the wrong thing to do to a listening
    /// session and unstable while the route is still settling — measured
    /// 2026-08-15, a connecting pair produced a continuous stream of
    ///
    ///     [vp::vx::Voice_Processor] failed to process downlink voice proc …
    ///     audio time stamp does not have valid sample time
    ///
    /// for as long as the tap was up. AirPods run their own noise suppression
    /// on-device, and the boosted barge-in threshold covers the echo case
    /// that VP was there for.
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
