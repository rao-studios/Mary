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

/// One runnable thing on the bench: an application-expertise operation, or a
/// Skill an expertise realizes.
struct SandRunnable: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A macUI recipe the package carries — the step list is known, so the
        /// timeline can show which step each act belongs to.
        case recipe(operation: String)
        /// A Skill exposed to the model. Its work may be an adapter read
        /// rather than a recipe, so there are no steps to attribute against.
        case skill
    }

    let id: String
    /// The name `dispatch` is called with.
    let invocation: String
    let title: String
    let summary: String
    let kind: Kind
    /// Recipe steps, in order, for attribution and for the step list.
    let steps: [PluginRecipeStepSchema]
    let inputs: [PluginOperationInputSchema]
    let packageID: PackageID
}

/// One application-expertise package, with what it can do.
struct SandPackage: Identifiable, Hashable {
    let id: PackageID
    let title: String
    let summary: String
    let tint: String
    let applicationTitle: String
    let bundleIdentifiers: [String]
    let runnables: [SandRunnable]
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

    // MARK: - Boot

    /// Build the graph and the runtime. Called once, from the root view.
    func start() {
        guard runtime == nil else { return }
        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()
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

    private func adopt(
        _ snapshot: AbilityRuntime.Snapshot, issues: [SchemaIssue], filesRead: Int?
    ) {
        self.snapshot = snapshot
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
                var runnables: [SandRunnable] = []

                // The recipes this expertise carries. `PluginManagedUIExecutor`
                // binds each operation under its own name, which is what
                // `dispatch` is called with.
                for operation in plugin?.operations ?? [] {
                    runnables.append(SandRunnable(
                        id: "recipe:\(operation.operation)",
                        invocation: operation.operation,
                        title: operation.title,
                        summary: operation.summary,
                        kind: .recipe(operation: operation.operation),
                        steps: operation.steps,
                        inputs: operation.inputs,
                        packageID: package.package.id))
                }

                // Skills this package exposes to the model in its own right.
                // An expertise usually owns none — it realizes a discipline's —
                // so this list is often empty and that is the honest answer.
                for skill in snapshot.exposedSkills
                where skill.packageID == package.package.id {
                    guard let invocation = skill.skill.modelExposure.invocationName,
                          !invocation.isEmpty,
                          !runnables.contains(where: { $0.invocation == invocation })
                    else { continue }
                    runnables.append(SandRunnable(
                        id: "skill:\(skill.skill.id.rawValue)",
                        invocation: invocation,
                        title: skill.skill.title,
                        summary: skill.skill.summary,
                        kind: .skill,
                        steps: [],
                        inputs: [],
                        packageID: package.package.id))
                }

                return SandPackage(
                    id: package.package.id,
                    title: package.ability.title,
                    summary: package.ability.summary,
                    tint: package.ability.tint,
                    applicationTitle: plugin?.application.title ?? package.ability.title,
                    bundleIdentifiers: plugin?.application.bundleIdentifiers ?? [],
                    runnables: runnables.sorted { $0.title < $1.title })
            }
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

    /// The parameters a Skill declares to the model. Recipes carry their own
    /// `inputs`; this is the other half.
    func parameters(forInvocation name: String) -> [ModelParameterSchema] {
        snapshot.skill(invocationName: name)?.skill.modelExposure.parameters ?? []
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
