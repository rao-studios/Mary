//
//  ComputerUseMonitor.swift
//  MaryComputerUse
//
//  WHAT: The one place that knows what the hands and eyes just did.
//  IN:   every lane, synchronously, at the moment it acts or refuses
//  OUT:  snapshot() for state, events() for activity, os_log for another process
//  PIN:  A LOCK, NOT AN ACTOR, and the reason is ordering. Every report site is
//        a synchronous static function — a key chord, a click, a menu press —
//        and hopping onto an actor would cost a task allocation per keystroke
//        chunk and could deliver an act after the refusal that followed it.
//        Reporting must never be able to fail, block, or reorder the act it
//        describes. Content never enters: shapes and counts only.
//

import ApplicationServices
import CoreGraphics
import Foundation
import os

public final class ComputerUseMonitor: @unchecked Sendable {

    /// The instance every lane reports into. Lives in whichever process
    /// performs the acts — a probe in another process watches the log mirror,
    /// not this object.
    public static let shared = ComputerUseMonitor()

    /// How much history a snapshot carries. Enough to answer "what just
    /// happened", short enough that it is never a recording.
    public static let ringCapacity = 64

    private struct State {
        var startedAt: Date
        var sequence: UInt64 = 0
        var lanes: [ComputerUseLane: ComputerUseLaneTally] = [:]
        var lastRefusal: ComputerUseRefusal?
        var sense = ComputerUseSenseTally()
        var recentActs: [ComputerUseAct] = []
        var recentRefusals: [ComputerUseRefusal] = []
        var observers: [UUID: AsyncStream<ComputerUseEvent>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> Date
    private let trusted: @Sendable () -> Bool
    private let screenRecording: @Sendable () -> Bool
    /// NOTICE, NOT INFO — and the level is load-bearing. `log stream` hides
    /// info-level lines unless asked, so an info mirror is a monitor that
    /// looks broken from the other process. These events are low-frequency
    /// and each one is worth seeing.
    private let log = Logger(subsystem: "nyc.rao.mary", category: "computer-use")

    /// Seams are injected so a test can drive time and permissions; the
    /// shared instance reads the real ones.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        trusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        screenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.now = now
        self.trusted = trusted
        self.screenRecording = screenRecording
        self.state = OSAllocatedUnfairLock(initialState: State(startedAt: now()))
    }

    // MARK: - Reporting

    /// Something happened. `detail` is shape, never content.
    public func note(
        lane: ComputerUseLane, act name: String,
        pid: pid_t? = nil, detail: String = ""
    ) {
        let event: ComputerUseEvent? = state.withLock { state in
            state.sequence += 1
            let act = ComputerUseAct(
                sequence: state.sequence, at: now(), lane: lane,
                name: name, pid: pid, detail: detail)
            var tally = state.lanes[lane] ?? ComputerUseLaneTally()
            tally.acts += 1
            tally.lastAct = act
            state.lanes[lane] = tally
            state.recentActs.append(act)
            if state.recentActs.count > Self.ringCapacity { state.recentActs.removeFirst() }
            return .act(act)
        }
        if case .act(let act) = event {
            log.notice("""
                act \(act.lane.rawValue, privacy: .public)/\(act.name, privacy: .public) \
                #\(act.sequence, privacy: .public) \(act.detail, privacy: .public)
                """)
        }
        emit(event)
    }

    /// Something did not happen, and this is why.
    public func note(
        lane: ComputerUseLane, refused name: String,
        pid: pid_t? = nil, reason: ComputerUseRefusalReason
    ) {
        let event: ComputerUseEvent? = state.withLock { state in
            state.sequence += 1
            let refusal = ComputerUseRefusal(
                sequence: state.sequence, at: now(), lane: lane,
                name: name, pid: pid, reason: reason)
            var tally = state.lanes[lane] ?? ComputerUseLaneTally()
            tally.refusals += 1
            tally.lastRefusal = refusal
            state.lanes[lane] = tally
            state.lastRefusal = refusal
            state.recentRefusals.append(refusal)
            if state.recentRefusals.count > Self.ringCapacity { state.recentRefusals.removeFirst() }
            return .refusal(refusal)
        }
        if case .refusal(let refusal) = event {
            log.notice("""
                refused \(refusal.lane.rawValue, privacy: .public)/\
                \(refusal.name, privacy: .public) #\(refusal.sequence, privacy: .public) — \
                \(refusal.reason.summary, privacy: .public)
                """)
        }
        emit(event)
    }

    /// One accessibility walk finished. COUNTED, NOT STREAMED: the ambient
    /// poll walks roughly every 1.5 seconds, and an event each time would bury
    /// the acts a person is watching for.
    public func noteSense(nodes: Int, duration: TimeInterval, truncated: Bool) {
        state.withLock { state in
            state.sense.walks += 1
            state.sense.totalNodes += nodes
            state.sense.lastNodes = nodes
            state.sense.lastDuration = duration
            if truncated { state.sense.truncatedWalks += 1 }
        }
    }

    // MARK: - Watching

    public func snapshot() -> ComputerUseSnapshot {
        let trusted = self.trusted()
        let recording = self.screenRecording()
        return state.withLock { state in
            ComputerUseSnapshot(
                startedAt: state.startedAt,
                accessibilityTrusted: trusted,
                screenRecordingGranted: recording,
                lanes: state.lanes,
                lastRefusal: state.lastRefusal,
                sense: state.sense,
                recentActs: state.recentActs,
                recentRefusals: state.recentRefusals)
        }
    }

    /// Live activity. Every monitor reads this instead of polling.
    ///
    /// PIN: the current state arrives FIRST, so a watcher that attaches after
    /// the interesting thing happened still sees where it landed.
    public func events() -> AsyncStream<ComputerUseEvent> {
        let current = snapshot()
        let id = UUID()
        let (stream, continuation) = AsyncStream<ComputerUseEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.ringCapacity))
        continuation.yield(.snapshot(current))
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.observers[id] = nil }
        }
        return stream
    }

    /// Forget everything. Tests only — the shared instance is the process's
    /// own memory of what it did.
    public func reset() {
        state.withLock { state in
            state.startedAt = now()
            state.sequence = 0
            state.lanes = [:]
            state.lastRefusal = nil
            state.sense = ComputerUseSenseTally()
            state.recentActs = []
            state.recentRefusals = []
        }
    }

    public var observerCount: Int { state.withLock { $0.observers.count } }

    private func emit(_ event: ComputerUseEvent?) {
        guard let event else { return }
        let observers = state.withLock { Array($0.observers.values) }
        for continuation in observers { continuation.yield(event) }
    }
}
