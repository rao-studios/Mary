//
//  AXSnapshotPoller.swift
//  Sand
//
//  WHAT: A live-enough stream of AXAppSnapshots for one process.
//  IN:   AXEngine.snapshot / AXEngine.detail — one-shot reads, on a cadence
//  OUT:  snapshots() for the stage, currentStats() for the HUD
//  PIN:  MARY POLLS, AND SO DOES SAND. Bonnie's Clyde rides an observer-driven
//        streamer with a display-link tracking pump; Mary's AXEngine has no
//        streamer by design ("Accessibility/ is read-only, one-shot"), and
//        inventing one inside an app would put the machine layer's cadence
//        somewhere no test can reach it. This poller lives in Sand instead —
//        it adds nothing to MaryComputerUse and takes nothing from it.
//        THE HONEST FRAME RATE: a full walk costs tens to hundreds of
//        milliseconds of IPC, so the cadence is a ceiling, never a promise.
//        The HUD prints what actually happened.
//        A publish only happens when the tree CHANGED — `AXAppSnapshot.==`
//        ignores capture time and walk duration, so a still screen costs one
//        walk per tick and no redraw.
//
import Foundation
import MaryComputerUse

actor AXSnapshotPoller {

    /// How hard to look. The bench raises this while a dispatch is in flight:
    /// a recipe's whole visible effect can land between two idle ticks.
    enum Cadence: String, Sendable, CaseIterable {
        /// Nothing is being watched closely.
        case idle
        /// A target is on the stage and a person is looking at it.
        case watching
        /// An ability is running right now.
        case running

        var interval: Duration {
            switch self {
            case .idle: return .milliseconds(1000)
            case .watching: return .milliseconds(250)
            case .running: return .milliseconds(100)
            }
        }

        var label: String {
            switch self {
            case .idle: return "idle (1 s)"
            case .watching: return "watching (250 ms)"
            case .running: return "running (100 ms)"
            }
        }
    }

    /// What the walk cost, for the HUD. The counterpart of Clyde's
    /// `AXSnapshotStreamer.Stats`, minus everything a streamer would know and
    /// a poller cannot (observer coverage, a wake verdict).
    struct Stats: Sendable {
        var lastWalkDuration: Duration?
        var nodeCount: Int = 0
        var publishedAt: Date?
        var isTruncated: Bool = false
        /// Publishes in the last second, recomputed on every read so it decays
        /// toward zero on a still screen instead of freezing at its last value.
        var publishHz: Double = 0
        var walks: Int = 0
        var webHost: WebContentHost.Kind?
        var cadence: Cadence = .watching

        init() {}
    }

    private let pid: pid_t
    private let bundleID: String?
    private let options: AXSnapshotBuilder.Options

    private var cadence: Cadence = .watching
    private var stats = Stats()
    private var publishTimes: [Date] = []
    private var previous: AXAppSnapshot?
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<AXAppSnapshot>.Continuation?

    init(
        pid: pid_t, bundleID: String?,
        options: AXSnapshotBuilder.Options = .init()
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.options = options
    }

    // MARK: - The stream

    func snapshots() -> AsyncStream<AXAppSnapshot> {
        let (stream, continuation) = AsyncStream<AXAppSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(2))
        self.continuation = continuation
        // The classifier is a one-shot read of what kind of app this is; it
        // never changes for a live pid, so it is asked once.
        stats.webHost = WebContentHost.classify(pid: pid, bundleID: bundleID)
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard let interval = await self?.cadence.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
        return stream
    }

    func setCadence(_ cadence: Cadence) {
        self.cadence = cadence
        stats.cadence = cadence
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - One walk

    private func tick() {
        let started = ContinuousClock.now
        // The walk itself is synchronous AX IPC. It runs on the actor's
        // executor, never the main one — a 200 ms walk on the main actor is a
        // 200 ms freeze of the very view that is supposed to show the cost.
        guard let snapshot = AXEngine.snapshot(pid: pid, options: options) else {
            // The target died, or accessibility went away. Neither is worth a
            // publish; the roster's terminate notification ends the session.
            return
        }
        let duration = ContinuousClock.now - started

        stats.walks += 1
        stats.lastWalkDuration = snapshot.walkDuration
        stats.nodeCount = snapshot.nodeCount
        stats.isTruncated = snapshot.windows.contains(where: \.isTruncated)

        // The machine layer counts every walk, whoever asked for it — so the
        // sense tally in Sand's own timeline and in `mary-ax-probe` agree.
        ComputerUseMonitor.shared.noteSense(
            nodes: snapshot.nodeCount,
            duration: TimeInterval(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18,
            truncated: stats.isTruncated)

        guard snapshot != previous else { return }
        previous = snapshot
        let now = Date()
        stats.publishedAt = now
        publishTimes.append(now)
        continuation?.yield(snapshot)
    }

    // MARK: - Reading

    func currentStats() -> Stats {
        let cutoff = Date().addingTimeInterval(-1)
        publishTimes.removeAll { $0 < cutoff }
        var current = stats
        current.publishHz = Double(publishTimes.count)
        current.cadence = cadence
        return current
    }

    /// The zoomed subtree's decoration. Parameterized IPC, dearer than the
    /// walk — the caller throttles it (see `WireframeViewModel`).
    func detail(for id: AXNodeID) -> AXSubtreeDetail? {
        AXEngine.detail(pid: pid, nodeID: id, budget: .probe)?.detail
    }
}
