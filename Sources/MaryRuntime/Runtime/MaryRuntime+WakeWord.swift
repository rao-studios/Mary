//
//  MaryRuntime+WakeWord.swift
//  Mary
//
//  THE COMPOSITION ROOT FOR "HEY Mary" — where the standby ear
//  (MaryVoice's WakeWordListener, which knows nothing of sessions), the
//  session lifecycle (VoiceService's reducers), and the user's choice
//  (ConfigService's `wakeWordEnabled`) are finally joined.
//
//  MODELLED ON `MaryRuntime+AmbientVoice` for the same reason that file
//  gives: `installBrainConfiguration` is called by every headless probe, and
//  standby must never arm without the app's — and the user's — consent.
//
//  THE ONE RULE: standby is armed exactly while
//      enabled && appReady && activeSessionCount == 0
//  and EVERY transition runs on one serial chain (`runChained`). The actor is
//  reentrant — an arm suspends for real engine-start time — so the chain, not
//  the actor, is what guarantees arm/disarm never interleave: no orphaned
//  hot microphone from a double arm, no standby mic surviving into a session,
//  no disarm racing the stop it is waiting on. `sessionWillStart` is awaited
//  by the Start reducer, and because it rides the same chain it returns only
//  after any in-flight arm has been waited out and its listener stopped.
//
//  SESSION CLAIMS ARE COUNTED, NOT FLAGGED. Two Starts can race (the mic
//  button vs. a wake handoff — the reason VoiceSessionBox.install is a Bool
//  claim); each claims here and releases exactly once, so a loser bailing or
//  a winner failing can never re-arm standby while the other still runs.
//

import MaryVoice
import Foundation
import os

/// The seams the controller acts through — recorded wholesale in tests.
package struct WakeStandbyHooks: Sendable {
    package var makeListener: @Sendable () async -> WakeWordListener
    /// Hand the wake to the normal session-start flow. nil remainder = bare
    /// wake (the Start reducer greets); non-nil = the first turn's query.
    package var startSession: @Sendable (String?) -> Void

    package init(
        makeListener: @escaping @Sendable () async -> WakeWordListener,
        startSession: @escaping @Sendable (String?) -> Void
    ) {
        self.makeListener = makeListener
        self.startSession = startSession
    }

    package static let live = WakeStandbyHooks(
        makeListener: {
            // The session's tuned thresholds, with voice processing OFF —
            // standby plays no audio to echo-cancel, and VP is what drags
            // Bluetooth routes into the call profile.
            var vad = await MainActor.run { MaryRuntime.wakeVADSource?() ?? VADConfig() }
            vad.voiceProcessing = false
            return WakeWordListener(
                config: WakeListenerConfig(vad: vad),
                selfSpeech: { await MaryRuntime.speaker.isSpeaking })
        },
        startSession: { remainder in
            guard MaryRuntime.admitVoiceStart() else { return }
            MaryRuntime.wakeHandoffBox.withLock {
                $0 = MaryRuntime.WakeHandoff(remainder: remainder, at: Date())
            }
            Task { @MainActor in
                guard let start = MaryRuntime.wakeSessionStart else {
                    MaryRuntime.releaseVoiceStart()
                    return
                }
                start()
            }
        })
}

package actor WakeStandbyController {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "wake")
    /// How long a failed arm waits before trying again (permissions may have
    /// arrived, a device may have settled).
    private static let retrySeconds: TimeInterval = 30
    /// How long after a wake handoff to re-check: a refused or failed Start
    /// must strand standby disarmed for seconds, not forever.
    private static let handoffNudgeSeconds: TimeInterval = 3

    private let hooks: WakeStandbyHooks
    /// How long a just-ended session's audio topology gets to settle before
    /// standby opens its own engine.
    ///
    /// ORDINARY HAL HYGIENE, not crash mitigation — the crashes it was first
    /// written for had a different cause (standby auto-binding an input device
    /// nobody picked; see `MicCapture`'s header rule), fixed at its source.
    /// Opening a capture engine into a teardown that is still unwinding is
    /// merely churn worth not causing, so this is short.
    private let rearmSettleSeconds: TimeInterval
    private var enabled = false
    private var appReady = false
    /// COUNTED, not a flag: concurrent Starts each claim and release once.
    private var activeSessionCount = 0
    private var listener: WakeWordListener?
    private var eventTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// The serial transition chain — see the header. Each link awaits its
    /// predecessor before touching the listener, and re-reads the CURRENT
    /// conditions when it runs rather than the ones at enqueue time.
    private var transitionChain: Task<Void, Never>?

    package init(
        hooks: WakeStandbyHooks,
        rearmSettle: TimeInterval = 0.5,
        sessionStartWaitBound: TimeInterval = 5
    ) {
        self.hooks = hooks
        self.rearmSettleSeconds = rearmSettle
        self.sessionStartWaitBound = sessionStartWaitBound
    }

    // MARK: - Transition edges

    package func setEnabled(_ on: Bool) async {
        enabled = on
        await runChained { await $0.reconcileNow() }
    }

    package func noteAppReady() async {
        appReady = true
        await runChained { await $0.reconcileNow() }
    }

    /// How long the Start reducer will wait for the standby engine to come
    /// down. A timeout aborts that Start: opening a second capture while the
    /// queued disarm is still live is an unsafe overlap, not a recovery.
    private let sessionStartWaitBound: TimeInterval

    /// AWAITED by the Start reducer before it opens the session microphone.
    /// `true` means the standby transition completed and this call owns one
    /// session claim. `false` means the wait expired; the claim is rolled back
    /// here and the caller must not construct/start a session capture.
    package func sessionWillStart() async -> Bool {
        activeSessionCount += 1
        retryTask?.cancel()
        retryTask = nil
        let prior = transitionChain
        let task = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            await self.reconcileNow()
        }
        transitionChain = task
        let bounded = await Self.awaitBounded(task, seconds: sessionStartWaitBound)
        if !bounded {
            activeSessionCount = max(0, activeSessionCount - 1)
            // The timed-out chain may already have evaluated `shouldArm`
            // while this claim was live and then suspended in listener.stop.
            // Queue a fresh read behind it so rollback cannot strand standby
            // disarmed after that stop eventually returns.
            scheduleReconcile(after: 0)
            Self.log.fault("standby disarm did not complete in \(self.sessionStartWaitBound)s — session start aborted")
            return false
        }
        return true
    }

    /// Await a task, but never past the bound. Returns false on timeout; the
    /// task keeps running and completes whenever its wedge clears.
    private static func awaitBounded(
        _ task: Task<Void, Never>, seconds: TimeInterval
    ) async -> Bool {
        final class Latch: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            private let continuation: CheckedContinuation<Bool, Never>
            init(_ continuation: CheckedContinuation<Bool, Never>) {
                self.continuation = continuation
            }
            func resume(_ completed: Bool) {
                lock.lock()
                let first = !resumed
                resumed = true
                lock.unlock()
                if first { continuation.resume(returning: completed) }
            }
        }
        return await withCheckedContinuation { continuation in
            let latch = Latch(continuation)
            Task {
                await task.value
                latch.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                latch.resume(false)
            }
        }
    }

    /// The Start loop's tail — where every REAL session end reports (Stop
    /// button, "stop listening", pipeline death alike). The re-arm is
    /// DEFERRED by the settle window (see `rearmSettleSeconds`): the session
    /// engines are still mid-HAL-teardown when the tail runs, and standby
    /// must not add a fourth engine to that storm.
    package func noteSessionEnded() async {
        activeSessionCount = max(0, activeSessionCount - 1)
        scheduleReconcile(after: rearmSettleSeconds)
    }

    /// The install-race loser's release: it claimed `sessionWillStart` but no
    /// session followed, and the winner's tail is not its to wait for.
    func noteSessionAborted() async {
        await noteSessionEnded()
    }

    /// Test seam: whether a listener is currently armed.
    package var isArmed: Bool { listener != nil }

    // MARK: - The serial chain

    private func runChained(
        _ body: @escaping @Sendable (WakeStandbyController) async -> Void
    ) async {
        let prior = transitionChain
        let task = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            await body(self)
        }
        transitionChain = task
        await task.value
    }

    private func reconcileNow() async {
        if shouldArm {
            await armNow()
        } else {
            await disarmNow()
        }
    }

    private var shouldArm: Bool { enabled && appReady && activeSessionCount == 0 }

    private func armNow() async {
        guard listener == nil, shouldArm else { return }
        let candidate = await hooks.makeListener()
        let events = await candidate.events()
        do {
            try await candidate.start()
        } catch {
            Self.log.notice("standby could not arm: \(error.localizedDescription)")
            scheduleReconcile(after: Self.retrySeconds)
            return
        }
        // The engine start suspended this actor for real time; the world may
        // have moved (a session claimed, the toggle flipped). A started
        // engine the conditions no longer want is stopped, not installed.
        guard shouldArm, listener == nil else {
            await candidate.stop()
            return
        }
        listener = candidate
        eventTask = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                await self?.handle(event)
            }
        }
        Self.log.info("standby armed")
    }

    private func disarmNow() async {
        eventTask?.cancel()
        eventTask = nil
        guard let held = listener else { return }
        // References cleared BEFORE the stop suspension, so nothing observing
        // this actor mid-stop can mistake a dying listener for an armed one.
        listener = nil
        await held.stop()
        Self.log.info("standby disarmed")
    }

    private func handle(_ event: WakeEvent) async {
        switch event {
        case .wake(let remainder):
            guard activeSessionCount == 0 else { return }
            await runChained { await $0.completeWake(remainder) }
        case .unavailable(let reason):
            // The listener already stopped itself; drop it and retry later.
            Self.log.notice("standby unavailable: \(reason)")
            eventTask?.cancel()
            eventTask = nil
            listener = nil
            scheduleReconcile(after: Self.retrySeconds)
        }
    }

    private func completeWake(_ remainder: String?) async {
        guard activeSessionCount == 0 else { return }
        // "Hey Mary, stop listening" while she is already off: starting a
        // session just to say goodbye would be absurd — stay armed, ignore.
        if let remainder, WakePlanner.isStopListening(remainder) { return }
        // Mic DOWN first — the session's capture must never overlap the
        // standby engine — then the normal Start flow, exactly as the button
        // sends it.
        await disarmNow()
        hooks.startSession(remainder)
        // If the Start was refused or failed, this re-arms; if it succeeded,
        // the session claim makes it a no-op.
        scheduleReconcile(after: Self.handoffNudgeSeconds)
    }

    private func scheduleReconcile(after seconds: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runChained { await $0.reconcileNow() }
        }
    }
}

extension MaryRuntime {

    package static let wakeStandby = WakeStandbyController(hooks: .live)

    /// Session-start seam, bound at boot to the ONE online VoiceService
    /// relay. A bare `VoiceService()` constructs a PRIVATE center whose sends
    /// reach nothing — Granite resolves the shared center only through
    /// `@Relay` — so the boot task installs a closure that captures the real
    /// relay's service. Nil until boot; a wake before then is impossible
    /// (standby arms only after `noteAppReady`).
    @MainActor package static var wakeSessionStart: (() -> Void)?
    /// Same binding story for the standby listener's VAD thresholds: read
    /// them through the online ConfigService relay, not a fresh instance.
    @MainActor package static var wakeVADSource: (() -> VADConfig)?

    /// Arm or disarm standby — a capability the user just revoked is not a
    /// capability (the AmbientVoice rule). FIFO through one chain: two quick
    /// toggle flips must land in the order the user made them, and detached
    /// `Task`s alone promise no order at all.
    static let wakeApplyChain = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    package static func applyWakeWord(_ enabled: Bool) {
        wakeApplyChain.withLock { chain in
            let prior = chain
            chain = Task {
                await prior?.value
                await wakeStandby.setEnabled(enabled)
            }
        }
    }

    /// What a wake-initiated Start carries: nil remainder greets, a query
    /// becomes the first turn. Rides a runtime box because the wake fires
    /// off-actor and the Start reducer is the one who consumes it.
    package struct WakeHandoff: Sendable {
        package var remainder: String?
        package var at: Date

        package init(remainder: String? = nil, at: Date) {
            self.remainder = remainder
            self.at = at
        }
    }

    package static let wakeHandoffBox = OSAllocatedUnfairLock<WakeHandoff?>(initialState: nil)

    /// Take-and-clear. Stale handoffs are dropped so a failed start can never
    /// replay a greeting under a later button press.
    package static func takeWakeHandoff() -> WakeHandoff? {
        let handoff = wakeHandoffBox.withLock { held -> WakeHandoff? in
            let value = held
            held = nil
            return value
        }
        guard let handoff, Date().timeIntervalSince(handoff.at) < 5 else { return nil }
        return handoff
    }
}

/// The bare-wake greetings, rotated so she doesn't say the same word all day.
package enum WakeGreetings {
    package static let lines = ["Yes?", "I'm listening.", "Go ahead.", "What do you need?"]
    private static let cursor = OSAllocatedUnfairLock<Int>(initialState: 0)

    package static func next() -> String {
        cursor.withLock { index in
            defer { index = (index + 1) % lines.count }
            return lines[index]
        }
    }
}
