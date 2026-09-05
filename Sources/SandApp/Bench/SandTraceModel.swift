//
//  SandTraceModel.swift
//  Sand
//
//  WHAT: One run, as a timeline: what the runtime asked for, what the machine
//        layer did, what it refused, and where on screen it happened.
//  IN:   ComputerUseMonitor.events() and BrowserEngine.live.events() (in-process),
//        AbilityExecutionLog, and optionally another Mary process's log mirror
//        (SandObserverTail)
//  OUT:  SandTimelineView rows and SandStageOverlay marks
//  PIN:  THE MONITOR IS THE SOURCE, NOT SAND. Every act and refusal on this
//        timeline was reported by the lane that performed it, in the order it
//        performed it — this file only stamps arrival time and groups by run.
//        STEP ATTRIBUTION IS INFERENCE, AND SAYS SO. The runtime does not tell
//        anyone which compiled step produced which act, so the timeline matches
//        acts to steps by lane and order. It is a reading aid; the acts
//        themselves are the evidence, and the UI labels the difference.
//        TWO STREAMS, ONE TIMELINE, AND THE INTERLEAVING IS THE EVIDENCE. The
//        machine layer says a click happened at a point; the browsing engine says
//        which phrase became which row and whether the page then moved. Neither
//        answers "did that do what was asked" alone — together, in arrival order,
//        they do.
//        A REFUSAL IS THE POINT. `ComputerUseRefusalReason` exists so a skipped
//        act says why — that line is usually the answer the bench was opened
//        for, so it is never collapsed or summarized away.
//
import Foundation
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin

/// One row of the timeline.
struct SandTraceEntry: Identifiable {
    enum Kind {
        case runBegan(invocation: String, runID: String, realization: String)
        case act(ComputerUseAct)
        case refusal(ComputerUseRefusal)
        case record(BehavioralActionRecord)
        case runEnded(summary: String, ok: Bool)
        /// The browsing engine's own stream — resolve, look, match, act, verify.
        /// Carries the engine's line verbatim (`BrowserEngineEvent.line`); the flag is
        /// the one thing the timeline colours differently.
        case browser(String, isRefusal: Bool)
        /// A line from ANOTHER process's mirror — the running Mary app.
        case external(text: String)
        case note(String)
    }

    let id = UUID()
    let at: Date
    let kind: Kind
    /// Milliseconds since the current run began, or nil outside a run.
    let offset: TimeInterval?
}

/// How far a compiled step got, as inferred from the acts that arrived.
enum SandStepStatus: Equatable {
    case pending
    case acted(name: String, detail: String)
    case refused(reason: String)
}

struct SandStepRow: Identifiable {
    let id: String
    let index: Int
    let kind: PluginRecipeStepKind
    let spelling: String
    var status: SandStepStatus
}

@MainActor
final class SandTraceModel: ObservableObject {

    @Published private(set) var entries: [SandTraceEntry] = []
    @Published private(set) var marks: [SandStageMark] = []
    @Published private(set) var steps: [SandStepRow] = []
    @Published private(set) var snapshot: ComputerUseSnapshot?
    @Published private(set) var isRunning = false
    /// The last run's outcome, kept after the run so the banner survives. `receipt` is
    /// the four facts that say whether the summary is true — see `receiptWords`.
    @Published private(set) var lastOutcome: (ok: Bool, summary: String, receipt: String)?

    /// How many rows the timeline keeps. Long enough for a whole recipe and
    /// its refusals, short enough that it is never a recording.
    static let capacity = 400

    private var monitorTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var ledgerTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private var currentRunID: String?
    /// Steps still unmatched, in order — the attribution cursor.
    private var pendingStepIndex = 0

    // MARK: - Watching

    /// Subscribe to this process's machine layer. The stream replays the
    /// current state first, so the grant chips are right from the first frame.
    func start() {
        guard monitorTask == nil else { return }
        let stream = ComputerUseMonitor.shared.events()
        monitorTask = Task { [weak self] in
            for await event in stream {
                await MainActor.run { self?.receive(event) }
            }
        }
        // THE BROWSING LANE'S OWN STREAM, beside the machine layer's. A browsing turn
        // is mostly decisions — which browser, which row, did the page move — and none
        // of them are acts, so a timeline with only `ComputerUseAct`s shows a click in
        // the middle of nowhere.
        browserTask = Task { [weak self] in
            for await event in await BrowserEngine.live.events() {
                await MainActor.run {
                    self?.append(.browser(event.line, isRefusal: event.isRefusal))
                }
            }
        }
        // Marks age out on their own; without a tick, a stale crosshair would
        // sit at full strength until the next event happened to arrive.
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { self?.pruneMarks() }
            }
        }
    }

    func stop() {
        monitorTask?.cancel(); monitorTask = nil
        browserTask?.cancel(); browserTask = nil
        ledgerTask?.cancel(); ledgerTask = nil
        pruneTask?.cancel(); pruneTask = nil
    }

    private func receive(_ event: ComputerUseEvent) {
        switch event {
        case .snapshot(let snapshot):
            self.snapshot = snapshot
        case .act(let act):
            append(.act(act))
            attribute(act: act)
            if let mark = Self.mark(for: act) { add(mark) }
            snapshot = ComputerUseMonitor.shared.snapshot()
        case .refusal(let refusal):
            append(.refusal(refusal))
            attribute(refusal: refusal)
            snapshot = ComputerUseMonitor.shared.snapshot()
        }
    }

    /// A line another Mary process wrote to the shared log mirror.
    func receiveExternal(_ text: String) {
        append(.external(text: text))
    }

    // MARK: - One run

    /// A run the TURN started. There is no `SandRunnable` behind it — the
    /// brain chose the name — so there are no authored steps to attribute
    /// against, and the timeline says who was expected to act instead.
    func beginRun(invocation: String, realization: String, runID: String) {
        runStartedAt = Date()
        currentRunID = runID
        pendingStepIndex = 0
        isRunning = true
        lastOutcome = nil
        marks = []
        steps = []
        append(.runBegan(invocation: invocation, runID: runID, realization: realization))
    }

    /// The ledger row the brain handed back. The turn lane never has a
    /// `SkillOutcome` of its own — the brain consumed it — so the record is
    /// both the outcome and the evidence.
    func endRun(record: BehavioralActionRecord) {
        isRunning = false
        let ok = record.disposition == .succeeded
        lastOutcome = (ok, record.summary, record.receiptWords)
        append(.runEnded(summary: record.summary, ok: ok))
        append(.record(record))
        if let mark = Self.mark(for: record) { add(mark) }
        currentRunID = nil
    }

    func beginRun(_ runnable: SandRunnable, runID: String) {
        runStartedAt = Date()
        currentRunID = runID
        pendingStepIndex = 0
        isRunning = true
        lastOutcome = nil
        marks = []
        steps = runnable.steps.enumerated().map { index, step in
            SandStepRow(
                id: step.id.isEmpty ? "step-\(index)" : step.id,
                index: index,
                kind: step.kind,
                spelling: Self.spelling(of: step),
                status: .pending)
        }
        // WHAT WAS EXPECTED, BEFORE ANYTHING ARRIVES. Naming the hands up
        // front is what makes an empty timeline legible: no acts under "via
        // Media Surface" means the adapter refused, not that nothing ran.
        append(.runBegan(
            invocation: runnable.invocation,
            runID: runID,
            realization: runnable.realizationWord))
        if runnable.steps.isEmpty, case .skill = runnable.kind {
            append(.note(
                "No authored steps — this Skill's hands are its adapter's, so the "
                + "acts below are whatever it reached for."))
        }
    }

    func endRun(outcome: SkillOutcome?, host: SandRuntimeHost, runID: String) {
        isRunning = false
        let ok = outcome?.ok ?? false
        let summary = outcome?.summary ?? "the runtime answered nothing"
        let receipt = outcome?.receiptWords ?? ""
        lastOutcome = (ok, summary, receipt)
        append(.runEnded(summary: summary, ok: ok))
        if !receipt.isEmpty { append(.note(receipt)) }
        // The ledger row lands from inside `dispatch`, which has already
        // returned by the time we get here — but the behavioral hand-off is
        // detached, so it is worth a short wait rather than a single look.
        ledgerTask?.cancel()
        ledgerTask = Task { [weak self] in
            for _ in 0..<20 {
                if let record = host.executionLog.entries().first(where: { $0.id == runID }) {
                    await MainActor.run {
                        self?.append(.record(record))
                        if let mark = Self.mark(for: record) { self?.add(mark) }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        currentRunID = nil
    }

    func clear() {
        entries = []
        marks = []
        steps = []
        lastOutcome = nil
    }

    // MARK: - Attribution (inference, labeled as such)

    /// Match an act to the next unmatched step whose kind belongs to that
    /// lane. Nothing is skipped over: a step that never gets an act keeps
    /// reading `pending`, which is exactly what "it stopped here" looks like.
    private func attribute(act: ComputerUseAct) {
        guard isRunning, pendingStepIndex < steps.count else { return }
        let step = steps[pendingStepIndex]
        guard Self.lane(for: step.kind) == act.lane else { return }
        steps[pendingStepIndex].status = .acted(name: act.name, detail: act.detail)
        pendingStepIndex += 1
    }

    private func attribute(refusal: ComputerUseRefusal) {
        guard isRunning, pendingStepIndex < steps.count else { return }
        let step = steps[pendingStepIndex]
        guard Self.lane(for: step.kind) == refusal.lane else { return }
        steps[pendingStepIndex].status = .refused(reason: refusal.reason.summary)
        pendingStepIndex += 1
    }

    /// Which lane performs a step of this kind. `wait` performs nothing, and a
    /// `rebindFocusedWindow` is a read the machine layer does not report.
    static func lane(for kind: PluginRecipeStepKind) -> ComputerUseLane? {
        switch kind {
        case .keyChord, .typeText: return .keyboard
        case .pointerMove, .pointerClick, .pointerDrag, .pointerSquareDrag, .scroll:
            return .pointer
        case .captureAccessibilityAnchor: return .pointer
        case .rebindFocusedWindow, .wait: return nil
        }
    }

    static func spelling(of step: PluginRecipeStepSchema) -> String {
        switch step.kind {
        case .keyChord:
            let modifiers = step.modifiers.map(\.rawValue).joined(separator: "+")
            let key = step.key?.rawValue ?? "?"
            return modifiers.isEmpty ? key : "\(modifiers)+\(key)"
        case .typeText: return "type text"
        case .wait: return String(format: "wait %.1fs", step.durationSeconds ?? 0)
        case .rebindFocusedWindow: return "rebind focused window"
        case .captureAccessibilityAnchor:
            return "capture anchor \(step.captureAnchor ?? "—")"
        case .pointerMove: return "move"
        case .pointerClick:
            return "click ×\(step.clickCount ?? 1) \(step.button?.rawValue ?? "left")"
        case .pointerDrag: return "drag"
        case .pointerSquareDrag: return "square drag"
        case .scroll: return "scroll"
        }
    }

    // MARK: - Marks

    /// A pointer act reports where it went as `(x,y)` — see
    /// `PointerDriver.describe`. Parsing that back is the only way to draw the
    /// point the machine layer ACTUALLY used, rather than the one the recipe
    /// asked for; when the format ever changes, the mark disappears and the
    /// timeline row stays, which is the right way round.
    static func mark(for act: ComputerUseAct) -> SandStageMark? {
        guard act.lane == .pointer, let point = parsePoint(act.detail) else { return nil }
        return SandStageMark(kind: .pointer(name: act.name), point: point)
    }

    /// The element the runtime recorded as acted on, with the frame it had at
    /// that moment. Screen space, top-left origin — the same space the
    /// wireframe's node frames are in.
    static func mark(for record: BehavioralActionRecord) -> SandStageMark? {
        guard let target = record.action.target else { return nil }
        let rect = target.frame.rect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return SandStageMark(
            kind: .acted(label: target.label.isEmpty ? target.role : target.label),
            rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    static func parsePoint(_ detail: String) -> CGPoint? {
        guard let open = detail.firstIndex(of: "("),
              let close = detail[open...].firstIndex(of: ")")
        else { return nil }
        let inner = detail[detail.index(after: open)..<close]
        let parts = inner.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func add(_ mark: SandStageMark) {
        marks.append(mark)
        pruneMarks()
    }

    private func pruneMarks() {
        let cutoff = Date().addingTimeInterval(-SandStageOverlay.lifetime)
        let kept = marks.filter { $0.at > cutoff }
        guard kept.count != marks.count else { return }
        marks = kept
    }

    // MARK: - Rows

    private func append(_ kind: SandTraceEntry.Kind) {
        let now = Date()
        entries.append(SandTraceEntry(
            at: now,
            kind: kind,
            offset: runStartedAt.map { now.timeIntervalSince($0) }))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
