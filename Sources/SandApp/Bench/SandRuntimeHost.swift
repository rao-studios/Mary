//
//  SandRuntimeHost.swift
//  Sand
//
//  WHAT: A real AbilityRuntime, in this process, over the real ability graph.
//  IN:   MaryAdapterCatalog + AbilityLibrary (the repo's Abilities/*.mary)
//  OUT:  the packages the bench lists, and dispatch(name:arguments:)
//  PIN:  THE SAME RUNTIME, NOT A MODEL OF IT. Sand dispatches through
//        `AbilityRuntime.dispatch` exactly as the turn loop does, so the route
//        into MaryComputerUse is the route — a bench that reimplemented the
//        path would only ever prove itself right.
//        NO MODEL, NO TOTEM, NO GRANITE: the runtime needs neither. What Sand
//        skips is the Seer-backed looking faculty and the coding agent, which
//        would need a network and a model to answer at all.
//        NOTHING PERSONAL IS TAUGHT. The habit memory providers are left
//        UNINSTALLED, so routing and application habits stay in memory and a
//        rehearsal on the bench never edits what Mary believes about this
//        person. The execution log is a private ring for the same reason.
//        THE STAGE IS THE LEAD. `focusProvider` names the application the
//        person put on the stage, because that IS this bench's arbitrated
//        answer — the whole gesture was choosing it. Without it the runtime
//        falls back to the frontmost window, which is Sand's own neighbour
//        (measured: a Calendar recipe blocked with "Chrome can\'t do this
//        yet" because Chrome happened to be in front), and every run would be
//        about whichever app the person alt-tabbed away from.
//
import Foundation
import os
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin

/// One runnable thing on the bench: a recipe the package carries, or a Skill
/// it realizes for a discipline it extends.
struct SandRunnable: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A macUI recipe this package carries. The step list is known, so the
        /// timeline can say which step each act belongs to.
        case recipe(operation: String)
        /// A Skill on the roster. Its hands may be this package's own recipe
        /// (`.localHands`) or a compiled adapter, which is exactly what the
        /// realization says.
        case skill(
            realization: AbilitySkillTile.Realization,
            readiness: SkillReadiness?,
            origin: AbilitySkillTile.Origin)
    }

    let id: String
    /// The name `dispatch` is called with. For a Skill this is the DISCIPLINE'S
    /// invocation name, never the realizing operation — see `SandLane`.
    let invocation: String
    let title: String
    let summary: String
    let kind: Kind
    /// Recipe steps, in order, for attribution and for the step list. Present
    /// for a recipe and for a Skill this package realizes with its own hands;
    /// empty for an adapter-realized Skill, which has no steps to show.
    let steps: [PluginRecipeStepSchema]
    let inputs: [PluginOperationInputSchema]
    let packageID: PackageID
    /// Cognitive, effectful, or workflow — see `natureWord`.
    let skillKind: SkillKind
    /// Why this row cannot be run, or nil when it can.
    let unrunnableReason: String?

    var isRunnable: Bool { unrunnableReason == nil }

    /// A row from the package's own recipe lane. Those are dispatched by
    /// operation name, which never appears on the model's roster.
    var isRecipe: Bool {
        if case .recipe = kind { return true }
        return false
    }

    /// "cognitive" / "workflow" / "" — what KIND of thing this is, when that
    /// changes what the timeline should be expected to show.
    var natureWord: String {
        guard case .skill = kind else { return "" }
        switch skillKind {
        case .cognitive: return "cognitive · instructs the turn, performs no act"
        case .workflow: return "workflow · runs other skills in order"
        default: return ""
        }
    }

    /// The short phrase the row prints for who carries this out.
    var realizationWord: String {
        switch kind {
        case .recipe(let operation): return "hands here · \(operation)"
        case .skill(let realization, _, _):
            if case .localHands(let operation) = realization {
                return "hands here · \(operation)"
            }
            return realization.word
        }
    }

    var readiness: SkillReadiness? {
        if case .skill(_, let readiness, _) = kind { return readiness }
        return nil
    }
}

/// One group of runnables, by the Ability that DEFINES them — the package's own
/// recipes, then each discipline it extends, then what it optionally supports.
struct SandLane: Identifiable, Hashable {
    let id: String
    let title: String
    let tint: String
    /// "recipes", "extends", "supporting" — why this lane is here.
    let note: String
    let runnables: [SandRunnable]
    var isCollapsedByDefault: Bool = false
}

/// One application-expertise package, with everything it can be asked to do.
struct SandPackage: Identifiable, Hashable {
    let id: PackageID
    let title: String
    let summary: String
    let tint: String
    let applicationID: String
    let applicationTitle: String
    let bundleIdentifiers: [String]
    let lanes: [SandLane]

    var runnables: [SandRunnable] { lanes.flatMap(\.runnables) }
}

@MainActor
final class SandRuntimeHost: ObservableObject {

    @Published private(set) var packages: [SandPackage] = []
    @Published private(set) var issues: [SchemaIssue] = []
    @Published private(set) var loadSummary: String = "not loaded"
    @Published private(set) var isDispatching = false

    /// A private ring, not `AbilityExecutionLog.shared` — the bench's runs are
    /// the bench's own memory.
    let executionLog = AbilityExecutionLog()

    private var runtime: AbilityRuntime?
    private var snapshot: AbilityRuntime.Snapshot = .empty
    private var libraryTask: Task<Void, Never>?
    /// The application id the stage is showing, read by `focusProvider` on
    /// whatever thread a dispatch happens to be on — hence the lock rather
    /// than a published property.
    private let leadApplicationID = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// The compiled adapters' own profiles, joined with the packages' on every
    /// activation — a taught app answers nil without them.
    private var nativeProfiles: [ApplicationProfile] = []

    // MARK: - Boot

    /// Build the graph and the runtime. Called once, from the root view.
    func start() {
        guard runtime == nil else { return }
        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()
        nativeProfiles = adapters.map(\.applicationProfile)
        // The package graph. `AbilityLibrary.defaultLocations` walks up from
        // its own source file to find this checkout's `Abilities/`, and honors
        // MARY_ABILITIES_PATH — so a bench launched from `.build/` reads the
        // same packages the app ships.
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])

        // THE SENSES STAY ASLEEP. Sand polls the one target a person picked;
        // activating the ambient observers would add a second, unrelated walk
        // lane to every timeline in this app.
        let lead = leadApplicationID
        runtime = AbilityRuntime(
            plugins: adapters,
            focusProvider: { lead.withLock { $0 } },
            executionLog: executionLog,
            contextProvider: { AbilityExecutionContext(projects: [:]) })

        adopt(load.snapshot, issues: load.issues, filesRead: load.filesRead)

        // A package edited in Ability Studio while Sand is open should show its
        // new recipe here without a relaunch.
        libraryTask = Task { [weak self] in
            for await event in AbilityLibrary.shared.events() {
                guard case .activated(let snapshot) = event else { continue }
                await MainActor.run { self?.adopt(snapshot, issues: [], filesRead: nil) }
            }
        }
    }

    /// Everything a dispatch needs the moment a graph activates — the same
    /// step the composition root runs (`MaryRuntime+BrainInstall`, step 3),
    /// minus the lanes that crawl.
    ///
    /// PIN: A TAUGHT APPLICATION IS NOT A PLAYER UNTIL THIS RUNS. The adapters
    /// are generic: `media-surface` learns that Apple Music's next button is
    /// called "Next" only because the package said so. Without the reconcile a
    /// bench dispatches `control_playback` and hears "Music isn't running"
    /// while Music is plainly running — measured, and the reason this exists.
    /// Corpus and awareness are deliberately NOT installed: they start crawls,
    /// and nothing here reads what they produce.
    private func installSurfaces(from snapshot: AbilityRuntime.Snapshot) {
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientApplicationBridge.install(
            profiles: nativeProfiles + snapshot.plugins.applicationProfiles)
        MediaSurfaceSupport.shared.reconcile(snapshot.mediaSurfaceRegistrations())
        ProseSurfaceSupport.shared.reconcile(snapshot.proseSurfaceRegistrations())
        CodeSurfaceSupport.shared.reconcile(snapshot.codeSurfaceRegistrations())
    }

    private func adopt(
        _ snapshot: AbilityRuntime.Snapshot, issues: [SchemaIssue], filesRead: Int?
    ) {
        self.snapshot = snapshot
        installSurfaces(from: snapshot)
        self.issues = issues
        self.packages = Self.expertisePackages(in: snapshot)
        let count = packages.count
        if let filesRead {
            loadSummary = "\(filesRead) packages read · \(count) expertises"
        } else {
            loadSummary = "\(count) expertises"
        }
    }

    // MARK: - What the bench can run

    /// Application-expertise packages only. An expertise is the paradigm that
    /// names a live application, which is the only kind of package whose route
    /// into MaryComputerUse is worth watching — a discipline's skills are
    /// realized BY one of these.
    private static func expertisePackages(
        in snapshot: AbilityRuntime.Snapshot
    ) -> [SandPackage] {
        snapshot.records
            .filter { $0.validation.isValid }
            .filter { $0.package.derivedParadigm == .applicationExpertise }
            .sorted { $0.package.package.id.rawValue < $1.package.package.id.rawValue }
            .map { record in
                let package = record.package
                let plugin = package.plugin
                var lanes: [SandLane] = []

                // 1. THE RECIPES THIS PACKAGE CARRIES, dispatched by operation
                // name — that is what `PluginManagedUIExecutor` binds them under.
                let recipes = (plugin?.operations ?? []).map { operation in
                    SandRunnable(
                        id: "recipe:\(operation.operation)",
                        invocation: operation.operation,
                        title: operation.title,
                        summary: operation.summary,
                        kind: .recipe(operation: operation.operation),
                        steps: operation.steps,
                        inputs: operation.inputs,
                        packageID: package.package.id,
                        skillKind: .effectful,
                        unrunnableReason: nil)
                }
                if !recipes.isEmpty {
                    lanes.append(SandLane(
                        id: "recipes",
                        title: package.ability.title,
                        tint: package.ability.tint,
                        note: "recipes",
                        runnables: recipes.sorted { $0.title < $1.title }))
                }

                // 2. THE SKILLS IT REALIZES. `AbilitySkillBench` is the same
                // derivation Ability Studio's Skills pane lays out: the
                // package's own skills, then each discipline it extends, then
                // what it optionally supports.
                let operationsByName = Dictionary(
                    (plugin?.operations ?? []).map { ($0.operation, $0) },
                    uniquingKeysWith: { first, _ in first })
                let bench = AbilitySkillBench(package: package, snapshot: snapshot)
                for lane in bench.lanes {
                    // The own-skills lane is empty for most expertises ("realizes
                    // what it extends"), and its recipes are already lane 1.
                    guard !lane.tiles.isEmpty else { continue }
                    let runnables = lane.tiles.map { tile in
                        Self.runnable(
                            tile: tile,
                            packageID: package.package.id,
                            operations: operationsByName)
                    }
                    lanes.append(SandLane(
                        id: "ability:\(lane.abilityID.rawValue)",
                        title: lane.title,
                        tint: lane.tint,
                        note: lane.note ?? "",
                        runnables: runnables.sorted { $0.title < $1.title },
                        isCollapsedByDefault: lane.isCollapsedByDefault))
                }

                return SandPackage(
                    id: package.package.id,
                    title: package.ability.title,
                    summary: package.ability.summary,
                    tint: package.ability.tint,
                    applicationID: plugin?.application.id
                        ?? package.applicationAffinities.first?.id ?? "",
                    applicationTitle: plugin?.application.title ?? package.ability.title,
                    bundleIdentifiers: plugin?.application.bundleIdentifiers ?? [],
                    lanes: lanes)
            }
    }

    /// One bench tile as something the bench can press.
    ///
    /// PIN: THE INVOCATION IS THE DISCIPLINE'S, NOT THE REALIZATION'S. Apple
    /// Music realizes `multimedia.open-player` with its own
    /// `apple_music_open_player` recipe, but dispatching that operation name
    /// directly asks the runtime for one exact provider and trips the
    /// frozen-provider guard. Asking for `open_player` lets the runtime resolve
    /// the expertise itself, which is the route this bench exists to watch.
    private static func runnable(
        tile: AbilitySkillTile,
        packageID: PackageID,
        operations: [String: PluginOperationSchema]
    ) -> SandRunnable {
        // Local hands mean the steps ARE knowable — the realizing operation is
        // in this package. An adapter-realized skill has none, and saying so
        // beats printing an empty step list that reads like a broken recipe.
        var steps: [PluginRecipeStepSchema] = []
        var inputs: [PluginOperationInputSchema] = []
        if case .localHands(let operation) = tile.realization,
           let schema = operations[operation] {
            steps = schema.steps
            inputs = schema.inputs
        }
        // ONLY A MISSING NAME BLOCKS A ROW. A cognitive primitive and a
        // workflow both dispatch perfectly well — the first instructs the turn
        // and performs no act, the second runs other skills — and a bench that
        // refused them would hide the two kinds whose ABSENCE of acts is the
        // interesting result. The nature word says which is which instead.
        let reason: String? = (tile.invocation?.isEmpty ?? true)
            ? "not exposed to the model, so there is no invocation name to dispatch"
            : nil
        return SandRunnable(
            id: "skill:\(tile.id.rawValue)",
            invocation: tile.invocation ?? "",
            title: tile.title,
            summary: tile.summary,
            kind: .skill(
                realization: tile.realization,
                readiness: tile.readiness,
                origin: tile.origin),
            steps: steps,
            inputs: inputs,
            packageID: packageID,
            skillKind: tile.kind,
            unrunnableReason: reason)
    }

    /// The application now on the stage. Named as the lead so the runtime
    /// resolves providers against what is being watched rather than against
    /// whatever window happens to be frontmost.
    func setStageTarget(bundleID: String?) {
        let id = applicationID(forBundleID: bundleID)
        leadApplicationID.withLock { $0 = id }
    }

    /// The plugin application id (`textedit`, `calendar`) a bundle id belongs
    /// to — the same id `ApplicationProfile` is keyed by.
    private func applicationID(forBundleID bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return snapshot.plugins.applicationProfiles.first { profile in
            profile.applicationIdentifiers.contains {
                $0.caseInsensitiveCompare(bundleID) == .orderedSame
            }
        }?.id
    }

    /// The expertise that teaches this bundle id, if one is installed — what
    /// the picker badges and the bench pre-selects.
    func package(forBundleID bundleID: String?) -> SandPackage? {
        guard let bundleID else { return nil }
        return packages.first { $0.bundleIdentifiers.contains(bundleID) }
    }

    /// The parameters the MODEL would be shown for this name, taken from the
    /// roster projection rather than the package.
    ///
    /// PIN: THE ROSTER KNOWS THINGS THE PACKAGE DOES NOT. `control_playback`'s
    /// `action` carries its enum (play/pause/next/previous/…) because the
    /// compiled adapter declares it; multimedia's own file says only "string".
    /// Reading the projection is what turns that field into a picker, and it is
    /// the same list the model gets — which is the point of a bench.
    func parameters(forInvocation name: String) -> [ModelSkillSchema.Parameter] {
        if let projected = runtime?.schemas.first(where: { $0.name == name }) {
            return projected.parameters
        }
        // Off the roster this turn (scoped out, or blocked): fall back to what
        // the package declares, so the form still shows what it would take.
        return (snapshot.skill(invocationName: name)?.skill.modelExposure.parameters ?? [])
            .map { declared in
                ModelSkillSchema.Parameter(
                    name: declared.name,
                    type: declared.type,
                    description: declared.summary,
                    required: declared.required,
                    enumValues: declared.enumValues.isEmpty ? nil : declared.enumValues)
            }
    }

    /// Why the runtime rates a skill the way it does — the availability
    /// evaluator's own sentences, shown behind the readiness chip.
    func availabilityReasons(forSkillNamed name: String) -> [String] {
        snapshot.skill(invocationName: name)?.availability.reasons ?? []
    }

    /// Whether this turn's roster offers the name.
    ///
    /// PIN: USED FOR PARAMETERS, NEVER AS A VERDICT. Read with no turn in
    /// flight this answers about a roster nobody asked for: `control_playback`
    /// reads "off roster" here and then dispatches, acts and succeeds, because
    /// the gates that dropped it are re-evaluated against the route the
    /// dispatch itself opens. Showing that as a warning said "this will not
    /// run" about a skill that runs.
    func isOnRoster(_ name: String) -> Bool {
        runtime?.schemas.contains { $0.name == name } ?? false
    }

    /// Whether the runtime would actually accept this name right now. A recipe
    /// whose package failed validation, or whose adapter is missing, is not on
    /// the roster — and saying so before the run beats a refusal that reads
    /// like a machine-layer failure.
    func isDispatchable(_ name: String) -> Bool {
        runtime?.knownSkillNames.contains(name) ?? false
    }

    // MARK: - Running one

    /// Dispatch, exactly as the turn loop does. `runID` is returned so the
    /// timeline can key its entries on the same identity the ledger uses.
    func dispatch(
        name: String, arguments: [String: String], runID: String
    ) async -> SkillOutcome? {
        guard let runtime else { return nil }
        isDispatching = true
        defer { isDispatching = false }
        // ONE RUN IS ONE TURN. The provider choice is memoized per turn and
        // frozen; without this, run two would answer with run one's lead.
        runtime.beginTurn()
        let json = Self.argumentsJSON(arguments)
        return await runtime.dispatch(name: name, argumentsJSON: json, runID: runID)
    }

    func cancel(runID: String) {
        runtime?.cancelRun(id: runID)
    }

    var runningRunIDs: Set<String> { runtime?.runningRunIDs ?? [] }

    /// Arguments the way the model would send them — a flat JSON object of
    /// strings, which is what `AbilityRuntime+Arguments` expects.
    static func argumentsJSON(_ arguments: [String: String]) -> String {
        let kept = arguments.filter { !$0.value.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: kept, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
