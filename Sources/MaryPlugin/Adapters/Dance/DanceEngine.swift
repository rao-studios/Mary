//
//  DanceEngine.swift
//  MaryPlugin
//
//  WHAT: The dance — a shader composed, admitted, rehearsed, and shown on the
//        canvas to a random beat; or held still as a mood.
//  IN:   DancePlugin
//  OUT:  DanceSnapshot + DanceEvent; pages through CanvasService
//  PIN:  THE LOOP OUTLIVES THE BINDING. A dispatch waits twenty seconds at
//        most and cancels its task; the beat runs in a task this actor owns,
//        and the binding returns the moment the first window is up.
//        NO SHADER, NO WINDOW. A composer that is not ready, a shader that is
//        refused three times, or a page that fails to compile three times is
//        a refusal with the reason in it — never a stand-in.
//

import CoreGraphics
import Foundation
import os

public enum DancePhase: String, Sendable, Equatable {
    case idle, composing, rehearsing, dancing, mood, closing
}

public enum DanceRefusal: Error, Sendable, Equatable {
    case composerUnavailable(String)
    case composerFailed(String)
    case shaderRefused(String)
    case compileFailed(String)
    case alreadyDancing
    case nothingToStop
    case canvas(CanvasRefusal)

    public var summary: String {
        switch self {
        case .composerUnavailable(let why): return "I can't compose a shader right now — \(why)"
        case .composerFailed(let why): return "The composer didn't answer — \(why)"
        case .shaderRefused(let why): return "My shader wouldn't do, even after two repairs: \(why)"
        case .compileFailed(let log): return "My shader didn't compile, even after two repairs: \(log)"
        case .alreadyDancing: return "I'm already dancing."
        case .nothingToStop: return "I wasn't dancing."
        case .canvas(let refusal): return refusal.summary
        }
    }
}

public enum DanceOutcome: Sendable, Equatable {
    case started(feeling: String)
    case refused(DanceRefusal)
}

public struct DanceSnapshot: Sendable, Equatable {
    public var phase: DancePhase
    public var feeling: String?
    public var windows: [CanvasWindowID]
    public var showing: Int
    public var beats: Int
    public var startedAt: Date?
    public var endsAt: Date?
    public var lastRefusal: DanceRefusal?
    public var recent: [String]
}

public enum DanceEvent: Sendable, Equatable {
    case composed(feeling: String, motifs: [String], repair: Bool)
    case rehearsed(ready: Bool, log: String?)
    case started(DancePhase)
    case beat(Int, shown: CanvasWindowID?, hidden: CanvasWindowID?)
    case finished(beats: Int)
    case stopped
    case dismissed(by: CanvasDismissal)
    case refused(DanceRefusal)
}

public actor DanceEngine {

    public struct Seams: Sendable {
        public var canvas: CanvasService
        public var compose: any DanceComposing
        public var sleep: @Sendable (Duration) async -> Void
        public var now: @Sendable () -> Date
        /// A number in the range, uniformly. Injected so a test can script the beat.
        public var random: @Sendable (ClosedRange<Double>) -> Double
        public var danceLength: Duration
        public var maximumWindows: Int

        public init(
            canvas: CanvasService,
            compose: any DanceComposing,
            sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = { Date() },
            random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
            danceLength: Duration = .seconds(15),
            maximumWindows: Int = 5
        ) {
            self.canvas = canvas
            self.compose = compose
            self.sleep = sleep
            self.now = now
            self.random = random
            self.danceLength = danceLength
            self.maximumWindows = maximumWindows
        }
    }

    /// The beat's bounds, in seconds.
    static let beatRange: ClosedRange<Double> = 0.25...0.9
    /// How long before the end every window comes down.
    static let tidyUp: Duration = .milliseconds(1500)
    /// How often a beat shows rather than hides, when both are possible.
    static let showBias = 0.65
    /// How many times a shader that compiled badly is sent back with the log.
    /// Two, measured: a small model's first slip is a type mismatch it fixes
    /// when shown the line; a second slip on the fix is common enough to be
    /// worth one more round, and a third is a refusal.
    static let compileRepairRounds = 2
    /// And how many times a shader admission refused — a texture, a
    /// #version — is sent back with the sentence. Cheap: no rehearsal.
    static let admissionRepairRounds = 2

    private let seams: Seams
    private var phase: DancePhase = .idle
    private var feeling: String?
    /// Every window this engine owns, prepared order.
    private var windows: [CanvasWindowID] = []
    private var beats = 0
    private var startedAt: Date?
    private var endsAt: Date?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var lastRefusal: DanceRefusal?
    private var recent: [String] = []
    private var observers: [UUID: AsyncStream<DanceEvent>.Continuation] = [:]

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "dance")

    public init(seams: Seams) {
        self.seams = seams
    }

    // MARK: - Monitoring

    public func snapshot() async -> DanceSnapshot {
        let showing = await seams.canvas.showing().filter { windows.contains($0) }.count
        return DanceSnapshot(
            phase: phase, feeling: feeling, windows: windows, showing: showing,
            beats: beats, startedAt: startedAt, endsAt: endsAt,
            lastRefusal: lastRefusal, recent: recent)
    }

    public func events() -> AsyncStream<DanceEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DanceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ event: DanceEvent) {
        let line: String
        switch event {
        case .composed(let feeling, let motifs, let repair):
            line = "composed \"\(feeling)\" motifs=\(motifs.joined(separator: ","))" + (repair ? " (repair)" : "")
        case .rehearsed(let ready, let log):
            line = "rehearsed ready=\(ready)" + (log.map { " log: \($0)" } ?? "")
        case .started(let phase): line = "started \(phase.rawValue)"
        case .beat(let n, let shown, let hidden):
            line = "beat \(n)" + (shown.map { " shown \($0)" } ?? "") + (hidden.map { " hidden \($0)" } ?? "")
        case .finished(let beats): line = "finished after \(beats) beats"
        case .stopped: line = "stopped"
        case .dismissed(let by): line = "dismissed by \(by)"
        case .refused(let refusal):
            lastRefusal = refusal
            line = "refused \(refusal.summary)"
        }
        recent.append(line)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        Self.log.info("\(line, privacy: .public)")
        for continuation in observers.values { continuation.yield(event) }
    }

    private func refuse(_ refusal: DanceRefusal) -> DanceOutcome {
        emit(.refused(refusal))
        phase = .idle
        return .refused(refusal)
    }

    // MARK: - The two acts

    /// Compose, rehearse, show the first window, and return — the beat goes on.
    public func dance(_ brief: DanceBrief) async -> DanceOutcome {
        guard phase != .dancing else { return refuse(.alreadyDancing) }
        if phase == .mood { await stopHolding() }
        generation += 1
        let mine = generation
        let brief = withMotifs(brief)

        let rehearsal: (fragment: GLSLFragment, feeling: String, first: CanvasWindowID)
        switch await composeAndRehearse(brief, title: "Mary dances", scale: 0.5) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let ready): rehearsal = ready
        }
        guard generation == mine else { return refuse(.alreadyDancing) }

        // THE REST OF THE TROUPE, prepared now so a beat is orderFront, not a
        // web-content launch.
        var prepared = [rehearsal.first]
        for index in 1..<max(1, seams.maximumWindows) {
            let seed = seams.random(0...1000)
            let page = ShaderPage.make(
                shader: rehearsal.fragment, title: "Mary dances · \(index + 1)", seed: seed, scale: 0.5)
            if case .success(let receipt) = await seams.canvas.prepare(
                page, placement: .fullScreen, onDismiss: dismissHook())
            {
                prepared.append(receipt.id)
            }
        }
        windows = prepared
        feeling = rehearsal.feeling
        phase = .dancing
        beats = 0
        startedAt = seams.now()
        endsAt = startedAt.map { $0.addingTimeInterval(Self.seconds(seams.danceLength)) }
        await seams.canvas.show(rehearsal.first, placement: .fullScreen)
        emit(.started(.dancing))

        loop = Task { [weak self] in
            await self?.beat(generation: mine)
        }
        return .started(feeling: rehearsal.feeling)
    }

    /// Compose, rehearse, show one window, and hold it.
    public func mood(_ brief: DanceBrief) async -> DanceOutcome {
        guard phase != .dancing else { return refuse(.alreadyDancing) }
        if phase == .mood { await stopHolding() }
        generation += 1
        let mine = generation
        let brief = withMotifs(brief)
        let title = brief.subject == .person ? "How you feel" : "How Mary feels"

        switch await composeAndRehearse(brief, title: title, scale: 1) {
        case .failure(let refusal):
            return refuse(refusal)
        case .success(let ready):
            guard generation == mine else { return refuse(.alreadyDancing) }
            windows = [ready.first]
            feeling = ready.feeling
            phase = .mood
            startedAt = seams.now()
            endsAt = nil
            await seams.canvas.show(ready.first, placement: .fullScreen)
            emit(.started(.mood))
            return .started(feeling: ready.feeling)
        }
    }

    /// Take everything down. False when there was nothing.
    @discardableResult
    public func stop() async -> Bool {
        guard phase != .idle else {
            _ = refuse(.nothingToStop)
            return false
        }
        generation += 1
        loop?.cancel()
        loop = nil
        phase = .closing
        await dismissMine()
        phase = .idle
        emit(.stopped)
        return true
    }

    // MARK: - Composing

    private func withMotifs(_ brief: DanceBrief) -> DanceBrief {
        guard brief.motifs.isEmpty else { return brief }
        var brief = brief
        brief.motifs = DanceMotifs.pick(random: seams.random)
        return brief
    }

    /// One composition, admitted, with one repair round for admission and one
    /// for compilation. The rehearsal window is the first window, kept.
    private func composeAndRehearse(
        _ brief: DanceBrief, title: String, scale: Double
    ) async -> Result<(fragment: GLSLFragment, feeling: String, first: CanvasWindowID), DanceRefusal> {
        phase = .composing
        var attempt: (fragment: GLSLFragment, feeling: String)
        switch await composeAdmitted(brief) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let admitted): attempt = admitted
        }

        phase = .rehearsing
        for round in 0...Self.compileRepairRounds {
            let seed = seams.random(0...1000)
            let page = ShaderPage.make(shader: attempt.fragment, title: title, seed: seed, scale: scale)
            let receipt: CanvasReceipt
            switch await seams.canvas.prepare(page, placement: .fullScreen, onDismiss: dismissHook()) {
            case .failure(let refusal): return .failure(.canvas(refusal))
            case .success(let prepared): receipt = prepared
            }
            emit(.rehearsed(ready: receipt.ready, log: receipt.log))
            if receipt.ready { return .success((attempt.fragment, attempt.feeling, receipt.id)) }
            _ = await seams.canvas.dismiss(receipt.id)
            let problem = receipt.log ?? "the page never reported it was ready"
            // MARY'S OWN REPAIR FIRST: an integer where a float belongs, on the
            // line the compiler named. A rehearsal is cheap; a model round is not.
            if let log = receipt.log, let mended = attempt.fragment.repaired(from: log) {
                let retry = ShaderPage.make(shader: mended, title: title, seed: seed, scale: scale)
                if case .success(let again) = await seams.canvas.prepare(
                    retry, placement: .fullScreen, onDismiss: dismissHook())
                {
                    emit(.rehearsed(ready: again.ready, log: again.log.map { "after Mary's own repair: \($0)" }))
                    if again.ready { return .success((mended, attempt.feeling, again.id)) }
                    _ = await seams.canvas.dismiss(again.id)
                }
            }
            guard round < Self.compileRepairRounds else { return .failure(.compileFailed(problem)) }
            var repair = brief
            repair.repair = .init(glsl: attempt.fragment.source, problem: "It did not compile: \(problem)")
            switch await composeAdmitted(repair, isRepair: true) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let admitted): attempt = admitted
            }
        }
        return .failure(.compileFailed("the page never reported it was ready"))
    }

    /// Ask, then admit — with `admissionRepairRounds` repairs when admission refuses.
    private func composeAdmitted(
        _ brief: DanceBrief, isRepair: Bool = false, admissionRound: Int = 0
    ) async -> Result<(fragment: GLSLFragment, feeling: String), DanceRefusal> {
        guard await seams.compose.isReady() else {
            return .failure(.composerUnavailable("the composer isn't ready."))
        }
        let composition: DanceComposition
        do {
            composition = try await seams.compose.compose(brief)
        } catch let error as DanceComposerError {
            switch error {
            case .unavailable(let why): return .failure(.composerUnavailable(why))
            case .failed(let why), .unparsable(let why): return .failure(.composerFailed(why))
            }
        } catch {
            return .failure(.composerFailed(error.localizedDescription))
        }
        emit(.composed(feeling: composition.feeling, motifs: brief.motifs, repair: isRepair))
        switch GLSLFragment.admit(composition.glsl) {
        case .success(let fragment):
            return .success((fragment, composition.feeling))
        case .failure(let refusal):
            guard admissionRound < Self.admissionRepairRounds else {
                return .failure(.shaderRefused(refusal.summary))
            }
            var repair = brief
            repair.repair = .init(glsl: composition.glsl, problem: refusal.summary)
            return await composeAdmitted(repair, isRepair: true, admissionRound: admissionRound + 1)
        }
    }

    // MARK: - The beat

    private func beat(generation mine: Int) async {
        guard let endsAt else { return }
        while generation == mine, !Task.isCancelled {
            let remaining = endsAt.timeIntervalSince(seams.now())
            guard remaining > Self.seconds(Self.tidyUp) else { break }
            let interval = seams.random(Self.beatRange)
            await seams.sleep(.milliseconds(Int(interval * 1000)))
            guard generation == mine, phase == .dancing, !Task.isCancelled else { return }
            await oneBeat()
        }
        guard generation == mine, phase == .dancing else { return }
        // The last breath: everything stays up until the end, then comes down.
        let remaining = max(0, endsAt.timeIntervalSince(seams.now()))
        await seams.sleep(.milliseconds(Int(remaining * 1000)))
        guard generation == mine, phase == .dancing else { return }
        phase = .closing
        await dismissMine()
        phase = .idle
        loop = nil
        emit(.finished(beats: beats))
    }

    private func oneBeat() async {
        let showing = await seams.canvas.showing().filter { windows.contains($0) }
        let hidden = windows.filter { !showing.contains($0) }
        beats += 1
        let wantsShow = showing.count < seams.maximumWindows
            && !hidden.isEmpty
            && (showing.count < 2 || seams.random(0...1) < Self.showBias)
        if wantsShow, let next = pick(hidden) {
            let placement = await randomPlacement()
            await seams.canvas.show(next, placement: placement)
            emit(.beat(beats, shown: next, hidden: nil))
        } else if let gone = pick(showing) {
            await seams.canvas.hide(gone)
            emit(.beat(beats, shown: nil, hidden: gone))
        } else {
            emit(.beat(beats, shown: nil, hidden: nil))
        }
    }

    private func pick(_ ids: [CanvasWindowID]) -> CanvasWindowID? {
        guard !ids.isEmpty else { return nil }
        let index = Int(seams.random(0...0.999_999) * Double(ids.count))
        return ids[min(max(index, 0), ids.count - 1)]
    }

    /// The whole screen one time in five; otherwise a rect a quarter to all
    /// of it on each side, somewhere it fits.
    private func randomPlacement() async -> CanvasPlacement {
        guard let screen = await seams.canvas.screenFrame() else { return .fullScreen }
        if seams.random(0...1) < 0.2 { return .fullScreen }
        let width = screen.width * seams.random(0.25...1)
        let height = screen.height * seams.random(0.25...1)
        let x = screen.minX + seams.random(0...max(0, screen.width - width))
        let y = screen.minY + seams.random(0...max(0, screen.height - height))
        return .rect(CGRect(x: x, y: y, width: width, height: height))
    }

    // MARK: - Leaving

    private func dismissHook() -> @Sendable (CanvasWindowID, CanvasDismissal) -> Void {
        { [weak self] id, by in
            Task { await self?.windowDismissed(id, by: by) }
        }
    }

    private func windowDismissed(_ id: CanvasWindowID, by dismissal: CanvasDismissal) async {
        guard let index = windows.firstIndex(of: id) else { return }
        windows.remove(at: index)
        guard dismissal != .caller else { return }
        emit(.dismissed(by: dismissal))
        // A click on the mood ends it; a preempt ends anything.
        if dismissal == .preempt || phase == .mood {
            generation += 1
            loop?.cancel()
            loop = nil
            if !windows.isEmpty {
                let remaining = windows
                windows = []
                for id in remaining { _ = await seams.canvas.dismiss(id) }
            }
            phase = .idle
        }
    }

    private func stopHolding() async {
        generation += 1
        loop?.cancel()
        loop = nil
        await dismissMine()
        phase = .idle
    }

    private func dismissMine() async {
        let mine = windows
        windows = []
        for id in mine { _ = await seams.canvas.dismiss(id) }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
