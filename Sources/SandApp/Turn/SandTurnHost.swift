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
    /// Why each skill was or was not offered — as the TURN projected it, from the
    /// brain's own observer.
    @Published fileprivate(set) var trace: AbilityRosterTrace = .empty
    /// What Mary said back.
    @Published private(set) var reply: String = ""
    /// True once a round has been asked for — the turn reached the model.
    @Published private(set) var askedTheModel = false
    /// WHAT THE TURN ACTUALLY DISPATCHED, in order.
    ///
    /// PIN: FOR A MEASUREMENT, NOT FOR THE PANE. The story rows already say this
    /// to a reader; a browsing trip has to compare it with what it expected, and
    /// re-deriving "which skill answered" from the rendered entries would be a
    /// second account of the turn that could disagree with the first.
    @Published private(set) var dispatchedNames: [String] = []
    /// The arguments the first dispatch went out with — the confidence lane's
    /// own filling, when it was the one that answered.
    @Published private(set) var dispatchedArguments: [String: String] = [:]

    /// Which embedding backend decides the roster, printed rather than assumed.
    var engineWord: String {
        switch MaryEmbeddings.engine() {
        case .appleNL: return "apple-nl"
        case .sewn(let model): return "sewn:\(model)"
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
        //
        // AND ONE ELEMENT INDEX, WITH A VECTORIZER IN IT. `BrainWiring` defaults to a
        // FRESH store, which is empty forever — so `addressCandidates` could never
        // answer and "addressed by its contents" never fired. Meanwhile the affordance
        // probe and the reference gate read `.shared` regardless, so without the
        // vectorizer installed here every slate a page read publishes is matched
        // lexically and the 0.90 floor is unreachable. Installed BEFORE the first
        // surface is published, because `noteElements` vectorizes at write time.
        if let vectorizer = MaryEmbeddings.vectorizer() {
            AmbientElementIndexStore.shared.installVectorizer(vectorizer)
        }
        let wiring = BrainWiring(
            containers: .shared,
            focusTracker: .shared,
            world: .shared,
            elementIndex: .shared,
            behavior: runtimeHost.behavior)
        let brain = MaryBrain(engine: engine, dispatcher: runtime, wiring: wiring)
        self.brain = brain

        let adapters = runtimeHost.adapters
        Task {
            await brain.setSystemPromptProvider {
                MaryPrompts.system(plugins: adapters, projects: [:])
            }
            // The turn's own preparer. Mary refreshes its observers here; Sand
            // publishes the one surface it already walked — and whatever the
            // adapters declare they perceive, so a turn about a player or a page is
            // arbitrated with the evidence Mary would have had. Accessibility only:
            // no pixels on a turn's own schedule.
            //
            // PIN: SAND'S OWN ADAPTERS, NOT THE CATALOG'S. This bench dispatches
            // through `MaryAdapterCatalog.adapters() + [AffordancePlugin()]`, and a
            // preparer that published from the catalog alone would arbitrate a turn
            // with evidence from a different set than the one that answers it — the
            // exact way a bench stops being a rehearsal.
            await brain.setTurnContextPreparer { [weak self] in
                await self?.publishStagedSurface()
                await TurnPerceptionPublisher.publishAll(adapters: adapters)
            }
            // THE ROSTER THE TURN USED, not one arbitrated afterwards. See
            // `refreshRouteAndTrace`, which now reads only the route.
            await brain.setRosterProjectionObserver { [weak self] trace in
                Task { @MainActor in self?.trace = trace }
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
        dispatchedNames = []
        dispatchedArguments = [:]
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

    // MARK: - Keeping what the bench learned

    /// Record this turn's sentence as a route fixture on the Skill that should
    /// have answered it.
    ///
    /// PIN: THE BENCH THAT FINDS A MIS-ROUTE COULD NOT RECORD ONE. Ability
    /// Studio could keep a sentence and Sand could not — so the tool that runs
    /// real turns, where a mis-route actually shows up, was the one with no way
    /// to write down what it found, and the fix had to be retyped into another
    /// window from memory. A route fixture is also the only lever that moves the
    /// skill tier at all (an ability's phrases feed the ability tier alone), so
    /// this is not a convenience: it is the repair.
    /// TAKES EFFECT ON THE NEXT LOAD. The indexes are built at registry reload,
    /// which is what the returned sentence says.
    func keepAsFixture(
        utterance: String,
        decision: AbilityRosterDecision,
        targetClass: String?
    ) -> String {
        let library = AbilityLibrary.shared
        let packageID = decision.reference.packageID
        do {
            let session = try library.beginEditingPackage(id: packageID)
            guard let data = session.draftJSON.data(using: .utf8) else {
                return "the package draft is not UTF-8"
            }
            let package = try AbilityPackageCodec.decode(data, verifyIntegrity: false)
            let updated = package.addingFixture(
                utterance: utterance,
                expectedSkill: decision.reference.skillID,
                targetClass: targetClass)
            guard updated.fixtures.count != package.fixtures.count else {
                return "\(packageID.rawValue) already says this"
            }
            let encoded = try AbilityPackageCodec.encoded(updated)
            guard let json = String(data: encoded, encoding: .utf8) else {
                return "could not re-encode \(packageID.rawValue)"
            }
            _ = try library.saveEditedPackage(json: json, session: session)
            return "kept in \(packageID.rawValue) — reaches the corpus on the next load"
        } catch {
            return "could not keep it: \(error.localizedDescription)"
        }
    }

    /// A line the bench itself puts on the story — `--auto` declining a round it cannot
    /// answer honestly, for instance. Same lane as the turn's own notes, so it reads in order.
    func note(_ text: String) {
        append(.note(text))
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
            dispatchedNames.append(reference.invocationName)
            if dispatchedArguments.isEmpty,
               let data = argumentsJSON.data(using: .utf8),
               let table = try? JSONSerialization.jsonObject(with: data)
                as? [String: String] {
                dispatchedArguments = table
            }
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

    /// The route only. THE ROSTER ARRIVES FROM INSIDE THE TURN.
    ///
    /// PIN: This used to read `runtime.abilityRosterTrace` as well, and that was wrong
    /// in a way that mattered: the property RE-ARBITRATES on demand, and it is called
    /// here from the turn's task rather than from within the turn's task-locals — so
    /// the frozen signals and the turn context were both absent and the answer
    /// described a different machine. On a confidence-lane dispatch, where the turn
    /// never reaches the second projection, the bench was showing a roster that had
    /// never existed. `setRosterProjectionObserver` publishes the real one.
    func refreshRouteAndTrace() {
        route = AmbientContextStore.shared.route()
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
