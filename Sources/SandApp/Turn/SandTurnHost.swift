//
//  SandTurnHost.swift
//  Sand
//
//  WHAT: One real turn, driven by hand.
//  IN:   an utterance; MaryBrain; SandBenchEngine; SandRuntimeHost's runtime
//  OUT:  the route, the roster trace, the model's round, the acts
//  PIN:  THE TURN IS MARY'S, NOT SAND'S. Everything that decides what may be
//        called — publishing the utterance, warming its vector, triage, the
//        route, the projection, the offer ledger, the no-model confidence lane
//        — happens inside `MaryBrain.respond(to:)`. Sand supplies the words and
//        the model's answer and watches. A bench that re-implemented those
//        steps would be testing its own copy of the rules, which is the one
//        result nobody needs.
//        WHY HOSTING RATHER THAN COPYING: `runTurn` binds four task-locals, two
//        of which (AbilityTurnContext, SchemaSignalTurnContext) are internal to
//        MaryBrain. Without the second, every published interaction and
//        perception is invisible to the roster. The brain can bind them; a
//        stranger cannot.
//
import Foundation
import MaryAmbient
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin
import MaryVoice

/// One line of the turn's story.
struct SandTurnEntry: Identifiable {
    enum Kind {
        case began(utterance: String)
        case invocation(name: String, argumentsJSON: String, runID: String)
        case result(summary: String, ok: Bool)
        case spoke(String)
        case note(String)
        case failed(String)
    }

    let id = UUID()
    let at: Date
    let kind: Kind
}

@MainActor
final class SandTurnHost: ObservableObject {

    @Published private(set) var entries: [SandTurnEntry] = []
    @Published private(set) var isRunning = false
    /// The round the brain is waiting on, or nil when it is not asking.
    @Published private(set) var round: SandModelRound?
    /// The route this turn resolved, read after the brain published it.
    @Published private(set) var route: AmbientRoute?
    /// Why each skill was or was not offered.
    @Published private(set) var trace: AbilityRosterTrace = .empty
    /// What Mary said back.
    @Published private(set) var reply: String = ""
    /// True once a round has been asked for — the turn reached the model.
    @Published private(set) var askedTheModel = false

    /// Which embedding backend decides the roster, printed rather than assumed.
    var engineWord: String {
        switch MaryEmbeddings.engine() {
        case .appleNL: return "apple-nl"
        case .seer(let model): return "seer:\(model)"
        case nil: return "lexical — no embedding asset"
        }
    }

    private var brain: MaryBrain?
    private var engine: SandBenchEngine?
    private weak var runtimeHost: SandRuntimeHost?
    private weak var trace_: SandTraceModel?
    private var turnTask: Task<Void, Never>?
    /// The stage's current snapshot, published as this turn's ambient surface.
    var stagedSurface: (() -> (snapshot: AXAppSnapshot, bundleID: String?)?)?

    // MARK: - Boot

    func start(runtimeHost: SandRuntimeHost, trace: SandTraceModel) {
        guard brain == nil, let runtime = runtimeHost.runtime else { return }
        self.runtimeHost = runtimeHost
        self.trace_ = trace

        let engine = SandBenchEngine(
            present: { [weak self] round in
                self?.round = round
                self?.askedTheModel = true
                // THE ROSTER IS ONLY TRUE AFTER THE ROUTE. `.turnBegan` fires
                // well before `noteRoute`, so a trace read there describes a
                // turn with no lead and no target classes — measured: it showed
                // an empty roster while the round beside it listed skills. A
                // round is the first moment both are settled.
                self?.refreshRouteAndTrace()
            },
            dismiss: { [weak self] id in
                if self?.round?.id == id { self?.round = nil }
            })
        self.engine = engine

        // ONE WORLD. The runtime already reads AmbientWorld.shared, and the
        // brain must write the utterance and the route into that same store or
        // the roster it projects describes a different machine.
        let wiring = BrainWiring(
            containers: .shared,
            focusTracker: .shared,
            world: .shared,
            behavior: BehavioralAssembler())
        let brain = MaryBrain(engine: engine, dispatcher: runtime, wiring: wiring)
        self.brain = brain

        let adapters = runtimeHost.adapters
        Task {
            await brain.setSystemPromptProvider {
                MaryPrompts.system(plugins: adapters, projects: [:])
            }
            // The turn's own preparer. Mary refreshes its observers here; Sand
            // publishes the one surface it already walked.
            await brain.setTurnContextPreparer { [weak self] in
                await self?.publishStagedSurface()
            }
        }
    }

    // MARK: - One turn

    func run(_ utterance: String) {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let brain, !isRunning else { return }
        isRunning = true
        askedTheModel = false
        entries = []
        reply = ""
        route = nil
        trace = .empty
        append(.began(utterance: text))

        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in brain.respond(to: text) {
                    if Task.isCancelled { break }
                    self.receive(event)
                }
            } catch {
                self.append(.failed(error.localizedDescription))
            }
            self.finish()
        }
    }

    func cancel() {
        engine?.abandonParkedRound()
        turnTask?.cancel()
        Task { [brain] in await brain?.cancel() }
    }

    /// The person's answer, as the model.
    func answer(_ answer: SandModelAnswer) {
        guard let round else { return }
        engine?.answer(answer, for: round.id)
    }

    private func receive(_ event: BrainEvent) {
        switch event {
        case .turnBegan:
            break
        case .token(let token):
            reply += token
        case .skillInvocation(let reference, let argumentsJSON, let runID):
            refreshRouteAndTrace()
            append(.invocation(
                name: reference.invocationName,
                argumentsJSON: argumentsJSON,
                runID: runID))
            // Key the act timeline on the brain's own run id, so the acts and
            // the ledger row belong to the same identity.
            trace_?.beginRun(
                invocation: reference.invocationName,
                realization: "the turn's own dispatch",
                runID: runID)
        case .skillResult(let record):
            append(.result(summary: record.summary, ok: record.disposition == .succeeded))
            trace_?.endRun(record: record)
        case .completed(let fullText):
            if !fullText.isEmpty { reply = fullText }
        default:
            break
        }
    }

    private func finish() {
        isRunning = false
        round = nil
        refreshRouteAndTrace()
        if !askedTheModel, entries.contains(where: { if case .invocation = $0.kind { return true }; return false }) {
            // THE SECOND THING THIS BENCH EXISTS TO SHOW. A turn that acted
            // without ever asking the model took the confidence lane: one skill
            // cleared the floor by the margin and its arguments were fillable
            // from the sentence.
            append(.note("dispatched on the confidence lane — no model round"))
        }
        if !reply.isEmpty { append(.spoke(reply)) }
    }

    /// PIN: `abilityRosterTrace`, never `projectRoster()`. The trace property
    /// arbitrates without recording a projection; `schemas` arms the offer
    /// ledger, and arming it from a view is what made the direct lane's
    /// behaviour depend on which SwiftUI render won a race.
    func refreshRouteAndTrace() {
        route = AmbientContextStore.shared.route()
        if let runtime = runtimeHost?.runtime {
            trace = runtime.abilityRosterTrace
        }
    }

    /// This turn's ambient surface, from the walk the stage already made.
    ///
    /// Mary's observers publish this every few seconds for every taught app;
    /// Sand watches one app and publishes that one. Without it the route has no
    /// place evidence and target-class gates have nothing to read.
    private func publishStagedSurface() async {
        guard let staged = stagedSurface?(), let bundleID = staged.bundleID else { return }
        let context = AXAmbientContext(snapshot: staged.snapshot)
        let place = AmbientPlaceResolver.applicationPlace(forBundleID: bundleID)
        AmbientContextStore.shared.noteSurface(
            AmbientBridge.surface(from: context, place: place))
    }

    private func append(_ kind: SandTurnEntry.Kind) {
        entries.append(SandTurnEntry(at: Date(), kind: kind))
    }
}
