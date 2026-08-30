//
//  AbilityRuntime.swift
//  MaryBrain
//
//  WHAT: Subshell dispatcher — primitives, plugin bindings, confirm/cancel.
//  IN:   AbilityDispatching (brain) + frozen snapshot
//  OUT:  SkillOutcome; writes held until spoken go-ahead
//  PIN:  Unknown Skills become spoken "that didn't work", never crashes.
//
import AppKit
import Foundation
import os

public final class AbilityRuntime: AbilityDispatching, @unchecked Sendable {

    public static let confirmSkillName = "confirm_pending_skill"
    public static let cancelSkillName = "cancel_pending_skill"
    /// Screen-look Skill name — settle policy and pre-look arm share this seam.
    public static let lookSkillName = "look_at_screen"

    private struct AttributedSkillBinding: Sendable {
        let owner: String   // plugin name; "" for standalone
        let binding: SkillBinding
    }

    private struct PluginRosterCache: Sendable {
        var revision: UUID?
        var bindings: [AttributedSkillBinding] = []
    }

    private let nativeAttributed: [AttributedSkillBinding]
    private let nativeProfiles: [ApplicationProfile]
    private let rosterCache = OSAllocatedUnfairLock<PluginRosterCache>(
        initialState: .init())
    /// Frozen provider choices for this turn. Cleared in `beginTurn()` beside `resolutions`.
    private let providerSelection = OSAllocatedUnfairLock<ProviderTurnSelection?>(
        initialState: nil)

    /// Skills offered this turn.
    /// PIN: Two generations — detached routines dispatch across `beginTurn`.
    private struct TurnOfferLedger: Sendable {
        var projected = false
        var current: Set<AbilityRosterSkillKey> = []
        var previous: Set<AbilityRosterSkillKey> = []
    }
    private let offerLedger = OSAllocatedUnfairLock<TurnOfferLedger>(
        initialState: .init())

    /// Call identity for the in-flight dispatch, carried to `performExecute`.
    /// PIN: Task-local rather than four extra parameters down the chain.
    enum RunContext {
        @TaskLocal static var runID: String?
    }

    private struct InFlightRun {
        /// Canceller for the in-flight worker (native or workflow — types differ).
        let cancel: @Sendable () -> Void
        /// Stop asked for this call. Cancelling a `Task` is a request, not a guarantee.
        var stopRequested = false
    }

    /// In-flight calls keyed by the id the Stop chip shows.
    private let inFlightRuns = OSAllocatedUnfairLock<[String: InFlightRun]>(
        initialState: [:])

    /// Ask one running call to stop. Safe after settle — a late stop is not an error.
    public func cancelRun(id: String) {
        let cancel = inFlightRuns.withLock { runs -> (@Sendable () -> Void)? in
            guard var run = runs[id] else { return nil }
            run.stopRequested = true
            runs[id] = run
            return run.cancel
        }
        cancel?()
    }

    /// Which calls are still running — the ids a Stop control may offer.
    public var runningRunIDs: Set<String> {
        Set(inFlightRuns.withLock { $0.keys })
    }

    /// Register this call's canceller; nil when nested (stop the owner).
    private func registerInFlight(
        _ cancel: @escaping @Sendable () -> Void
    ) -> String? {
        guard let identity = RunContext.runID else { return nil }
        inFlightRuns.withLock { $0[identity] = InFlightRun(cancel: cancel) }
        return identity
    }

    private func releaseInFlight(_ identity: String?) {
        guard let identity else { return }
        inFlightRuns.withLock { $0[identity] = nil }
    }

    private func wasStopRequested(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return inFlightRuns.withLock { $0[identity]?.stopRequested ?? false }
    }
    private var attributed: [AttributedSkillBinding] {
        let snapshot = abilitySnapshot
        let dynamic = rosterCache.withLock { cache -> [AttributedSkillBinding] in
            if cache.revision == snapshot.revision { return cache.bindings }
            let nativeNames = Set(nativeAttributed.map { $0.binding.name })
            var seen = nativeNames
            // Every imported operation enters Mary's compiled native-interaction interpreter.
            let managedUI = PluginManagedUIExecutor.shared.runtimeBindings(in: snapshot)
                .map { (owner: $0.owner, binding: $0.binding) }
            cache.bindings = managedUI
                .compactMap { item in
                    guard seen.insert(item.binding.name).inserted else { return nil }
                    return AttributedSkillBinding(
                        owner: item.owner,
                        binding: item.binding)
                }
            cache.revision = snapshot.revision
            return cache.bindings
        }
        return nativeAttributed + dynamic
    }
    private var skillBindings: [SkillBinding] { attributed.map(\.binding) }
    /// Plugin id → targeted-read binding. Fetch-first uses this; runtime never names plugin Skills.
    private let targetedReads: [String: (binding: String, parameter: String)]
    /// Plugin id → its revision verb, and plugin id → its half of the passage contract.
    private let targetedEdits: [String: (binding: String, parameter: String)]
    private let passageBackings: [String: PassageBacking]

    /// World each binding owner serves when the owner's id does not spell it.
    private let servedWorlds: [String: AmbientWorld]
    private let contextProvider: @Sendable () -> AbilityExecutionContext
    /// Plugin whose Skills hoist to the front of the roster. Nil keeps natural order.
    private let focusProvider: (@Sendable () -> String?)?
    private let pendingStore: PendingSkillStore
    /// Session ledger for real executions — leaves only, so parked confirms stay off it.
    private let executionLog: AbilityExecutionLog
    /// Episode sink for this turn's actions. Nil in tests (no fake episode).
    private let behavior: BehavioralAssembler?
    /// Ambient store — this dispatcher is one of its four writers.
    private let ambient: AmbientContextStore
    /// Handle ledger. Injected so tests locate without minting into the process-wide store.
    private let passages: PassageRegistry
    /// Addressable-container identity. A document-keyed read is evidence for one container.
    private let containers: ContainerRegistry
    /// Applications this runtime knows, for owners the world enum cannot name.
    private let applicationsOverride: (any AmbientApplicationIndex)?
    private var applications: any AmbientApplicationIndex {
        applicationsOverride ?? AmbientApplicationIndexProvider.current
    }
    /// This turn's Skill-name → attributed-index map (nil = miss). Cleared in `beginTurn`.
    private let resolutions = OSAllocatedUnfairLock<[String: Int?]>(initialState: [:])
    /// Surface referent for this turn. Only trusted Design resolution may arm it.
    private let surfaceReferent = OSAllocatedUnfairLock<AbilitySurfaceReferent>(
        initialState: .currentLiveSelection)

    /// `SemanticSkillRequestIndex.affinities(in:)` memoized for the turn (same freeze as `providerSelection`).
    private let semanticSkillAffinityCache = OSAllocatedUnfairLock<
        (utterance: String, affinities: [SkillID: Float])?
    >(initialState: nil)

    public init(
        plugins: [any MaryAdapter],
        standalone: [SkillBinding] = [],
        focusProvider: (@Sendable () -> String?)? = nil,
        executionLog: AbilityExecutionLog = .shared,
        behavior: BehavioralAssembler? = nil,
        ambient: AmbientContextStore = .shared,
        passages: PassageRegistry = .shared,
        containers: ContainerRegistry = .shared,
        applications: (any AmbientApplicationIndex)? = nil,
        contextProvider: @escaping @Sendable () -> AbilityExecutionContext
    ) {
        var seen = Set<String>()
        var attributedBindings: [AttributedSkillBinding] = []
        let all = plugins.flatMap { plugin in plugin.skillBindings.map { (plugin.name, $0) } }
            + standalone.map { ("", $0) }
        for (owner, binding) in all {
            guard seen.insert(binding.name).inserted else {
                assertionFailure("Duplicate binding name: \(binding.name)")
                continue
            }
            attributedBindings.append(AttributedSkillBinding(owner: owner, binding: binding))
        }
        self.behavior = behavior
        self.nativeAttributed = attributedBindings
        self.nativeProfiles = plugins.map(\.applicationProfile)
        var reads: [String: (binding: String, parameter: String)] = [:]
        var edits: [String: (binding: String, parameter: String)] = [:]
        var backings: [String: PassageBacking] = [:]
        var worlds: [String: AmbientWorld] = [:]
        for plugin in plugins {
            // Observation adapter serving a differently-named world: register under both keys.
            if let served = plugin.servedWorld, served.pluginOwner != plugin.name {
                worlds[plugin.name] = served
            }
            if let targeted = plugin.targetedRead {
                reads[plugin.name] = targeted
                if let served = plugin.servedWorld, served.pluginOwner != plugin.name {
                    reads[served.pluginOwner] = targeted
                }
                for alias in plugin.targetedReadAliases where alias != plugin.name {
                    reads[alias] = targeted
                }
            }
            // Both halves or neither: verb without backing cannot locate; backing without verb cannot send.
            if let verb = plugin.targetedEdit {
                edits[plugin.name] = verb
            }
        }
        self.targetedReads = reads
        self.targetedEdits = edits
        self.passageBackings = backings
        self.servedWorlds = worlds
        self.contextProvider = contextProvider
        self.focusProvider = focusProvider
        self.executionLog = executionLog
        self.ambient = ambient
        self.passages = passages
        self.containers = containers
        self.applicationsOverride = applications
        self.pendingStore = PendingSkillStore()
    }

    // MARK: - AbilityDispatching

    /// Schema count without building schemas — same three terms `schemas` assembles.
    public var schemaCount: Int {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        recordProjectedRoster(roster)
        let scope = placeScope()
        let visible = attributed.reduce(into: 0) { count, item in
            guard admits(owner: item.owner, scope: scope) else { return }
            guard let skill = snapshot.skill(bindingOperation: item.binding.name) else {
                count += 1
                return
            }
            // Same one-projection-per-Skill rule `projectedSchema` applies.
            guard turnOperation(for: skill, snapshot: snapshot) == item.binding.name
            else { return }
            if roster.contains(skill) { count += 1 }
        }
        let schemaExecuted = snapshot.skills.filter {
            $0.skill.execution.kind != .binding
                && roster.contains($0)
        }.count
        return visible + schemaExecuted
            + (pendingStore.current() != nil ? 2 : 0)
    }

    public var applicationProfiles: [ApplicationProfile] {
        nativeProfiles + abilitySnapshot.plugins.applicationProfiles
    }
    public var focusedApplicationID: String? {
        // Injected focus resolver — the turn's already-arbitrated answer.
        if let resolvedOwner = focusProvider?(),
           let resolved = applicationProfiles.first(where: {
               $0.id.caseInsensitiveCompare(resolvedOwner) == .orderedSame
           }) {
            return resolved.id
        }
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier?.lowercased() else { return nil }
        return Self.applicationID(
            forBundleIdentifier: bundleIdentifier,
            profiles: applicationProfiles)
    }

    static func applicationID(
        forBundleIdentifier bundleIdentifier: String,
        profiles: [ApplicationProfile]
    ) -> String? {
        let bundleIdentifier = bundleIdentifier.lowercased()
        if let exact = profiles.first(where: { profile in
            profile.applicationIdentifiers.contains {
                $0.lowercased() == bundleIdentifier
            }
        }) {
            return exact.id
        }
        return profiles.first { profile in
            guard let prefix = profile.applicationBundlePrefix else {
                return false
            }
            return PluginApplicationSchema.bundleIdentifier(
                bundleIdentifier,
                isInFamily: prefix)
        }?.id
    }
    public var abilitySnapshot: AbilityRuntimeSnapshot {
        AbilityTurnContext.snapshot ?? AbilityLibrary.shared.snapshot()
    }
    public var abilityRosterTrace: AbilityRosterTrace {
        let snapshot = abilitySnapshot
        return rosterArbitration(
            snapshot: snapshot,
            context: abilityRoutingContext()).trace
    }

    public func skillReference(for invocationName: String) -> AbilitySkillReference {
        let snapshot = abilitySnapshot
        var reference = snapshot.reference(forInvocation: invocationName)
        // Chips print this turn's provider, not the static preference.
        if let runtime = snapshot.skill(invocationName: invocationName),
           runtime.reference.invocationName == invocationName,
           let choice = turnProviderSelection(snapshot: snapshot)
               .choice(for: runtime.skill.id) {
            reference.adapterID = choice.binding.adapterID
            reference.bindingOperation = choice.binding.operation
            reference.provider = choice.provider
        }
        return reference
    }

    public var schemas: [ModelSkillSchema] {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        recordProjectedRoster(roster)
        // Stable partition: the focused plugin's Skill bindings hoist to the front; within-group order is preserved.
        let scope = placeScope()
        var ordered = attributed.filter { admits(owner: $0.owner, scope: scope) }
        if let hoisted = focusProvider?(),
           ordered.contains(where: { $0.owner == hoisted }) {
            ordered = ordered.filter { $0.owner == hoisted }
                + ordered.filter { $0.owner != hoisted }
        }
        // Preference is package data, applied as a stable tuning signal after Mary has formed the safe/focused candidate roster.
        ordered = ordered.enumerated().sorted { lhs, rhs in
            let left = snapshot.skill(bindingOperation: lhs.element.binding.name)?
                .skill.routing.preference ?? 0
            let right = snapshot.skill(bindingOperation: rhs.element.binding.name)?
                .skill.routing.preference ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        var result: [ModelSkillSchema] = []
        let schemaExecuted = snapshot.skills
            .filter { $0.skill.execution.kind != .binding }
            .sorted {
                if $0.skill.routing.preference == $1.skill.routing.preference {
                    return $0.skill.id.rawValue < $1.skill.id.rawValue
                }
                return $0.skill.routing.preference > $1.skill.routing.preference
            }
        result.append(contentsOf: schemaExecuted.compactMap {
            projectedSchema(for: $0, roster: roster)
        })
        result.append(contentsOf: ordered.compactMap {
            projectedSchema(for: $0.binding, snapshot: snapshot, roster: roster)
        })
        // Raw machine primitives are escape hatches, so typed Ability Skills lead the roster.
        if pendingStore.current() != nil {
            result.append(ModelSkillSchema(
                name: Self.confirmSkillName,
                description: "Execute the Skill invocation waiting for the user's confirmation. Call ONLY after the user has clearly agreed.",
                parameters: []
            ))
            result.append(ModelSkillSchema(
                name: Self.cancelSkillName,
                description: "Discard the Skill invocation waiting for confirmation. Call when the user declines or changes the subject.",
                parameters: []
            ))
        }
        return result
    }

    /// Project the portable Skill schema onto the provider-neutral callable contract.
    private func projectedSchema(
        for binding: SkillBinding,
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration
    ) -> ModelSkillSchema? {
        guard let runtime = snapshot.skill(bindingOperation: binding.name) else {
            return binding.schema
        }
        // One projection per Skill. Every compatible candidate materializes (rivals included).
        guard turnOperation(for: runtime, snapshot: snapshot) == binding.name else {
            return nil
        }
        guard roster.contains(runtime) else { return nil }
        let exposure = runtime.skill.modelExposure
        let parameters: [ModelSkillSchema.Parameter]
        if exposure.inheritsBindingContract && exposure.parameters.isEmpty {
            parameters = binding.parameters
        } else {
            parameters = exposure.parameters.map { projected in
                let adapterDescription = binding.parameters.first(where: {
                    $0.name == projected.name
                })?.description
                return ModelSkillSchema.Parameter(
                    name: projected.name,
                    type: projected.type,
                    description: adapterDescription ?? "Typed input \(projected.name).",
                    required: projected.required,
                    enumValues: projected.enumValues.isEmpty ? nil : projected.enumValues)
            }
        }
        return ModelSkillSchema(
            name: runtime.reference.invocationName,
            description: projectedBindingDescription(
                binding.description,
                for: runtime,
                bindingOperation: binding.name,
                snapshot: snapshot),
            parameters: parameters)
    }

    /// Dynamic operation semantics are a last-mile model-selection hint, not a routing input.
    private func projectedBindingDescription(
        _ base: String,
        for runtime: AbilityRuntimeSkill,
        bindingOperation: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> String {
        guard snapshot.validation.isValid else { return base }
        let providerSelection = turnProviderSelection(snapshot: snapshot)
        guard providerSelection.mismatch(for: runtime.skill.id) == nil else {
            return base
        }
        let selected = providerSelection.choice(for: runtime.skill.id)?.binding
            ?? runtime.availability.selectedBinding
        guard let selected,
              selected.operation == bindingOperation,
              let realization = snapshot.plugins.realization(
                  skillID: runtime.skill.id,
                  adapterID: selected.adapterID,
                  operation: selected.operation),
              let record = snapshot.package(id: realization.originPackageID),
              record.validation.isValid,
              let plugin = record.package.plugin,
              let operation = plugin.operations.first(where: {
                  $0.operation == selected.operation
                      && plugin.adapter(for: $0)?.id == selected.adapterID
              })
        else { return base }

        var hint = ""
        if let semantics = operation.semantics {
            let role: String
            switch semantics.role {
            case .utility: role = "utility"
            case .observe: role = "observe"
            case .createArtifact: role = "create artifact"
            case .mutateArtifact: role = "mutate existing artifact"
            }
            hint = "Semantic role: \(role). This hint distinguishes only among model tools already admitted by Ability, application, and Skill routing; it never grants application, target, or Skill authority."
            if semantics.role == .createArtifact, !semantics.aliases.isEmpty {
                hint += " Validated creation subjects: \(semantics.aliases.joined(separator: ", "))."
            }
        }
        // Closed caution sentence — distinct from `semantics` above and from inspector-only title/summary.
        if let caution = operation.caution {
            if !hint.isEmpty { hint += " " }
            hint += Self.cautionSentence(for: caution)
        }
        guard !hint.isEmpty else { return base }
        return "\(base) \(hint)"
    }

    /// The fixed, Mary-owned sentence for one closed `GuardrailCategory` at operation granularity.
    static func cautionSentence(for category: GuardrailCategory) -> String {
        switch category {
        case .domainMismatch:
            return "Domain caution: do not use this outside the surface kind it was built for (for example, prose vs. code)."
        case .unscopedTarget:
            return "Scope caution: applies only to the target the user explicitly named or focused, never an inferred neighbor."
        case .staleState:
            return "Freshness caution: read live state before acting or reporting; never answer from a remembered value."
        case .noFocusSteal:
            return "Focus caution: never bring the target forward or steal focus merely to observe or command it."
        case .nativeCommandOnly:
            return "Command caution: this issues the target application's own command; never substitute synthesized input for it."
        case .irreversibleAction:
            return "Irreversible caution: this can destroy or replace existing content; confirm the exact, fresh target before acting."
        }
    }

    /// Cognitive and workflow Skills — no Plugin binding; schema-executed.
    private func projectedSchema(
        for runtime: AbilityRuntimeSkill,
        roster: AbilityRosterArbitration
    ) -> ModelSkillSchema? {
        guard roster.contains(runtime) else { return nil }
        switch runtime.skill.execution.kind {
        case .binding:
            return nil
        case .cognitive:
            return CognitivePrimitiveCatalog.modelSchema(for: runtime)
        case .stateMachine:
            let exposure = runtime.skill.modelExposure
            return ModelSkillSchema(
                name: runtime.reference.invocationName,
                description: "Run this validated Mary workflow. Every step is bounded and resolves to an installed Skill or a closed Mary cognitive primitive before execution begins.",
                parameters: exposure.parameters.map {
                    ModelSkillSchema.Parameter(
                        name: $0.name,
                        type: $0.type,
                        description: "Typed workflow input \($0.name).",
                        required: $0.required,
                        enumValues: $0.enumValues.isEmpty ? nil : $0.enumValues)
                })
        }
    }

    /// What may execute — facts provable without this turn's phrasing.
    private func dispatchEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if !runtime.skill.modelExposure.enabled {
            return "is not exposed for model invocation"
        }
        // Binding confirms resume via `PendingSkillStore`; workflows do not — block top-level `.confirm`.
        if runtime.skill.execution.kind == .stateMachine,
           runtime.skill.access == .confirm {
            return "requires a resumable workflow confirmation boundary"
        }
        if policy.requiresStage && !runtime.skill.usesStage {
            return "does not declare the stage required by its Capability contract"
        }
        if policy.requiresUserConfirmation && runtime.skill.access != .confirm {
            return "does not declare the user confirmation required by its Capability contract"
        }
        if policy.allowedTargetClasses?.isEmpty == true {
            return "has conflicting Capability target-class allowlists"
        }
        if runtime.availability.readiness != .ready {
            return runtime.availability.reasons.first
                ?? "has no available adapter binding"
        }
        let requiredInteractions = Set(runtime.skill.requirements.interactions)
        let missingInteractions = requiredInteractions.subtracting(context.interactions)
        if let missing = missingInteractions.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires current Interaction \(missing.rawValue)"
        }
        let requiredPerceptions = Set(runtime.skill.requirements.perceptions)
        let missingPerceptions = requiredPerceptions.subtracting(context.perceptions)
        if let missing = missingPerceptions.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires current Perception \(missing.rawValue)"
        }
        let requiredCapabilities = Set(runtime.skill.requirements.capabilities)
        let executableCapabilities = context.capabilities.union(
            CognitivePrimitiveCatalog.internalCapabilities(for: runtime))
        let missingCapabilities = requiredCapabilities.subtracting(executableCapabilities)
        if let missing = missingCapabilities.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires available Capability \(missing.rawValue)"
        }
        let supportingAbilities = Set(
            runtime.skill.requirements.supportingAbilities
                + runtime.ability.operatingPolicy.defaultSupportingAbilities)
        if let missing = supportingAbilities
            .filter({ !snapshot.containsAbility($0) })
            .sorted(by: { $0.rawValue < $1.rawValue }).first {
            return "requires supporting Ability \(missing.rawValue)"
        }
        let effect = snapshot.effect(
            forInvocation: runtime.reference.invocationName)
        if let failure = routedSignalSnapshot()
            .mutationAuthorizationFailure(for: runtime.skill, effect: effect) {
            return failure
        }
        if runtime.skill.execution.kind == .stateMachine,
           let failure = workflowExecutionSafetyFailure(
               for: runtime,
               snapshot: snapshot) {
            return failure
        }
        return nil
    }

    /// Advisory routing predicates over this turn's keyword reading.
    /// PIN: These decide what Mary offers, not what may execute.
    private func routingEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext
    ) -> String? {
        if !AbilityRoutingEvaluator.isEligible(runtime.ability.routing, in: context) {
            return "does not match its Ability-level routing policy"
        }
        if !AbilityRoutingEvaluator.isEligible(runtime.skill.routing, in: context) {
            return "does not match this turn's source and routing context"
        }
        return nil
    }

    /// What may be offered — executable set, narrowed by relevance.
    /// PIN: Pre-arbitration gate; input diet unchanged by later filters.
    private func projectionEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        dispatchEligibilityFailure(for: runtime, in: context, snapshot: snapshot)
            ?? routingEligibilityFailure(for: runtime, in: context)
    }

    /// Closed arbitration starts from the projection gate's safe set and can only remove Skills.
    private func eligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration? = nil
    ) -> String? {
        if let failure = projectionEligibilityFailure(
            for: runtime,
            in: context,
            snapshot: snapshot) {
            return failure
        }
        let roster = roster ?? rosterArbitration(snapshot: snapshot, context: context)
        return roster.failure(for: runtime)
    }

    /// Record the roster as projected, before place-scope and one-projection filters.
    /// PIN: Pre-filter set.
    private func recordProjectedRoster(_ roster: AbilityRosterArbitration) {
        offerLedger.withLock {
            $0.projected = true
            $0.current.formUnion(roster.selectedKeys)
        }
    }

    /// Was this Skill offered this turn? The roster's one authorization claim.
    private func offerLedgerFailure(
        for runtime: AbilityRuntimeSkill,
        roster: AbilityRosterArbitration
    ) -> String? {
        // Offerable right now: nothing to say.
        if roster.contains(runtime) { return nil }
        let ledger = offerLedger.withLock { $0 }
        // Nothing projected — deterministic path, host call, or test-only dispatch.
        guard ledger.projected else { return nil }
        let key = AbilityRosterSkillKey(runtime)
        if ledger.current.contains(key) || ledger.previous.contains(key) { return nil }
        // Prefer the arbitrator's sentence — it names the Skill to call instead.
        guard let arbitration = roster.failure(for: runtime) else {
            return "was not offered in this turn's Skill roster"
        }
        return "was not offered in this turn's Skill roster — it \(arbitration)"
    }

    private func rosterArbitration(
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityRoutingContext
    ) -> AbilityRosterArbitration {
        AbilityRosterArbitrator.arbitrate(
            skills: snapshot.skills,
            context: context) { [self] runtime in
                projectionEligibilityFailure(
                    for: runtime,
                    in: context,
                    snapshot: snapshot)
            }
    }

    /// Snapshot readiness proves schema-level resolution.
    private func workflowExecutionSafetyFailure(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntimeSnapshot,
        visiting: Set<SkillID> = []
    ) -> String? {
        guard runtime.skill.execution.kind == .stateMachine else { return nil }
        guard !visiting.contains(runtime.skill.id) else {
            return "contains a recursive workflow cycle"
        }
        var nextVisiting = visiting
        nextVisiting.insert(runtime.skill.id)
        for step in runtime.skill.execution.steps {
            if let target = snapshot.skill(invocationName: step.operation) {
                if target.availability.readiness != .ready {
                    return "step \(step.id) targets an unavailable Skill"
                }
                if target.skill.access == .confirm {
                    return "step \(step.id) crosses an undeclared confirmation boundary"
                }
                switch target.skill.execution.kind {
                case .binding:
                    guard let operation = target.bindingOperation,
                          let local = attributed.first(where: {
                              $0.binding.name == operation
                          })?.binding
                    else {
                        return "step \(step.id) has no exact local implementation"
                    }
                    if local.access == .write {
                        return "step \(step.id) requires resumable user confirmation"
                    }
                case .cognitive:
                    guard CognitivePrimitiveCatalog.contract(for: target) != nil else {
                        return "step \(step.id) targets an unknown cognitive primitive"
                    }
                case .stateMachine:
                    if let failure = workflowExecutionSafetyFailure(
                        for: target,
                        snapshot: snapshot,
                        visiting: nextVisiting) {
                        return "step \(step.id) cannot run: \(failure)"
                    }
                }
            } else if CognitivePrimitiveCatalog.contract(
                workflowOperation: step.operation,
                abilityID: runtime.ability.id) == nil {
                return "step \(step.id) names unresolved operation \(step.operation)"
            }
        }
        return nil
    }

    private func blockedOutcome(
        runtime: AbilityRuntimeSkill,
        reason: String
    ) -> SkillOutcome {
        SkillOutcome(
            ok: false,
            summary: "\(runtime.reference.displayLabel) is unavailable: \(reason).",
            status: .blocked,
            archivePolicy: .none,
            skillReference: runtime.reference)
    }

    /// The immutable turn signal set after semantic route containment.
    private func routedSignalSnapshot() -> SchemaSignalTurnSnapshot {
        let snapshot = SchemaSignalTurnContext.snapshot ?? .empty
        let route = ambient.route()
        guard let rejectedAttention = route?.attention,
              rejectedAttention.tier == .selection,
              route?.selectionDefinesTurn != true
        else { return snapshot }
        let rejectedHandoffID = ambient.selectionHandoff(
            world: rejectedAttention.world)?.id
        // Code or prose — asked of the registration, not a name.
        let rejectedSchema: InteractionID =
            rejectedAttention.place.focus == .coding
            ? .codeSelection
            : .textSelection
        return SchemaSignalTurnSnapshot(
            interactions: snapshot.interactions.filter {
                if let rejectedHandoffID {
                    return $0.id != rejectedHandoffID
                }
                // Handoff identity missing: fail closed on this schema, keep the other family.
                return $0.reference.schemaID != rejectedSchema
            },
            perceptions: snapshot.perceptions)
    }

    /// Turn routing verdict. Internal (not private) so taught-app parity tests can read it.
    func abilityRoutingContext() -> AbilityRoutingContext {
        let route = ambient.route()
        let windowIntent = windowManagementTurnIntent(route: route)
        let diagnosticAttention = route?.attention
        // Keep the source packet on AmbientRoute for diagnostics and event ordering
        let excludesDiagnosticSelection = diagnosticAttention?.tier == .selection
            && route?.selectionDefinesTurn != true
        let attention = excludesDiagnosticSelection ? nil : diagnosticAttention
        let facts = ambient.facts()
        let handoff = attention.flatMap {
            ambient.routedSelectionHandoff(world: $0.world)
        }
        var interactions: Set<InteractionID> = []
        let signalSnapshot = routedSignalSnapshot()
        let routingInteractions = signalSnapshot.interactions
        interactions.formUnion(routingInteractions.map { $0.reference.schemaID })
        var interactionEvidenceRanks: [InteractionID: Int] = [:]
        for interaction in routingInteractions {
            let id = interaction.reference.schemaID
            interactionEvidenceRanks[id] = max(
                interactionEvidenceRanks[id] ?? 0,
                interaction.evidenceRank)
        }
        // Selection becomes a routable Interaction only after the schema bridge validates it.
        var perceptions = signalSnapshot.perceptionIDs
        if let lead = route?.leadPlace {
            // Native lead earns focus perception for leading — same as before.
            if lead.worldClass == .workspace {
                perceptions.insert(.workspaceFocus)
                perceptions.insert(.projectFocus)
            }
            if lead.focus == .coding {
                perceptions.insert(.codeWorkspaceFocus)
            }
        }
        if attention?.applicationID != nil
            || route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            perceptions.insert(.applicationFocus)
        }
        if handoff?.scope.windowID != nil { perceptions.insert(.windowFocus) }
        if attention?.tier == .hover { perceptions.insert(.hover) }
        if facts.contains(where: { $0.slot == .viewport }) {
            perceptions.insert(.viewport)
        }

        // Source resolution is the most specific fact this turn can prove.
        func rank(_ value: SourceResolution) -> Int {
            switch value {
            case .unresolved: return 0
            case .device: return 1
            case .application: return 2
            case .window: return 3
            case .workspace: return 4
            case .document: return 5
            }
        }
        var sourceResolution = handoff?.scope.resolution
            ?? ((attention?.applicationID != nil || route?.leadApplicationID != nil)
                ? .application : .unresolved)
        func promote(_ candidate: SourceResolution) {
            if rank(candidate) > rank(sourceResolution) { sourceResolution = candidate }
        }
        for interaction in routingInteractions {
            promote(interaction.reference.scope.resolution)
        }
        for perception in signalSnapshot.perceptions {
            promote(perception.reference.scope.resolution)
        }
        if let lead = route?.leadPlace, lead.worldClass == .workspace {
            promote(.workspace)
            // `$0.place == lead`, NOT `$0.world == lead`.
            let leadFacts = facts.filter { $0.place == lead }
            if leadFacts.contains(where: {
                $0.slot == .file && $0.subject?.isEmpty == false
            }) {
                promote(.document)
            }
        } else if route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            promote(.application)
        }
        // Workspace family is the lead place's ability — not an inline two-value switch.
        let workspaceFamily: String? = route?.leadPlace?.ability?.rawValue
        let capabilities = Set(
            abilitySnapshot.bindings
                .filter { $0.adapter.isAvailable }
                .flatMap { $0.adapter.capabilities })
        let grantedPermissions = Set(
            abilitySnapshot.adapterManifests
                .filter(\.isAvailable)
                .flatMap(\.grantedPermissions))
        var targets = Set(route?.namedPlaces.map(\.token) ?? [])
        targets.formUnion(windowIntent.targetClasses)
        if let lead = route?.leadPlace {
            targets.insert(lead.token)
            targets.insert(lead.worldClass.rawValue)
            // Lead's target classes come from its package.
            // PIN: Used to be a switch over compiled worlds.
            if let registration = AmbientApplicationIndexProvider.current
                .registration(place: lead) {
                targets.formUnion(registration.profile.targetClasses)
            }
        }
        if attention?.selectionEditability == .editable,
           attention?.place.focus != .coding {
            targets.insert("editable-prose-surface")
        }
        if let writingTarget = route?.writingTarget?.rawValue {
            targets.insert(writingTarget)
        }
        // Taught workspace classes come from its package.
        if let leadApplicationID = route?.leadApplicationID,
           let registration = AmbientApplicationIndexProvider.current
            .registration(id: leadApplicationID) {
            targets.formUnion(registration.profile.targetClasses)
        }
        // World class from the lead place. The block above stays keyed on `route.lead`.
        if let leadPlace = route?.leadPlace {
            targets.insert(leadPlace.worldClass.rawValue)
        }
        var namedApplications = Set(route?.gate.applications ?? [])
        if let id = route?.leadPlace?.application { namedApplications.insert(id) }
        if let leadApplicationID = route?.leadApplicationID {
            namedApplications.insert(leadApplicationID)
        }
        if let applicationID = attention?.applicationID {
            namedApplications.insert(applicationID)
        }
        let normalizedApplicationIDs = Set(namedApplications.map { $0.lowercased() })
        for profile in applicationProfiles where
            normalizedApplicationIDs.contains(profile.id.lowercased())
                || !Set(profile.applicationIdentifiers.map { $0.lowercased() })
                    .isDisjoint(with: normalizedApplicationIDs) {
            targets.formUnion(profile.targetClasses)
        }
        // One vectorization for the whole turn — scorer is called per Skill across passes.
        let utterance = ambient.utterance()
        return AbilityRoutingContext(
            utterance: utterance,
            intent: route?.intent.rawValue,
            namedApplications: namedApplications,
            targetClasses: targets,
            interactions: interactions,
            interactionEvidenceRanks: interactionEvidenceRanks,
            perceptions: perceptions,
            capabilities: capabilities,
            grantedPermissions: grantedPermissions,
            sourceResolution: sourceResolution,
            workspaceFamily: workspaceFamily,
            semanticSkillAffinity: semanticSkillAffinities(for: utterance))
    }

    /// See `semanticSkillAffinityCache`. One vectorization and one library scan per turn.
    private func semanticSkillAffinities(for utterance: String) -> [SkillID: Float] {
        if let cached = semanticSkillAffinityCache.withLock({ $0 }),
           cached.utterance == utterance {
            return cached.affinities
        }
        let computed = abilitySnapshot.semanticSkillIndex?
            .affinities(in: utterance) ?? [:]
        semanticSkillAffinityCache.withLock { $0 = (utterance, computed) }
        return computed
    }

    /// The window-classifier's view of the turn.
    private func windowManagementTurnIntent(
        route: AmbientRoute?
    ) -> WindowManagementTurnIntent {
        let referent = ambient.referent()
        let index = AmbientApplicationIndexProvider.current

        // Document-holding place that leads: referent, then lead, then named.
        let candidates: [AmbientPlace] = [
            referent?.place, route?.leadPlace,
        ].compactMap { $0 } + Array(route?.namedPlaces ?? [])

        let place = candidates.first { candidate in
            index.registration(place: candidate)?.observesDocuments == true
        }
        let documentPlace = place.flatMap { candidate -> WindowManagementDocumentPlace? in
            guard let id = candidate.application else { return nil }
            return WindowManagementDocumentPlace(
                applicationID: id,
                documentNoun: index.registration(place: candidate)?
                    .documentNoun ?? "document",
                isReferent: referent?.place == candidate)
        }
        return WindowManagementTurnClassifier.classify(
            utterance: ambient.utterance(),
            documentPlace: documentPlace)
    }

    /// Whether this is an acting application turn covered by a typed operation or by that operation's frozen provider refusal.
    private func selectedTypedAbilityCoversApplicationTurn(
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration,
        routing: AbilityRoutingContext
    ) -> Bool {
        guard ["operate", "compose", "revise"].contains(routing.intent ?? "")
        else { return false }
        let hasApplicationContext = !routing.namedApplications.isEmpty
            || routing.perceptions.contains(.applicationFocus)
            || routing.sourceResolution == .application
            || routing.sourceResolution == .window
            || routing.sourceResolution == .workspace
            || routing.sourceResolution == .document
        guard hasApplicationContext else { return false }

        let providerSelection = turnProviderSelection(snapshot: snapshot)
        return snapshot.skills.contains { runtime in
            runtime.skill.modelExposure.enabled
                && runtime.skill.execution.kind != .cognitive
                && (roster.contains(runtime)
                    || providerSelection.mismatch(for: runtime.skill.id) != nil)
        }
    }

    public func beginTurn() {
        pendingStore.beginTurn()
        // Matcher memo is this turn's leading world. See `resolutions`.
        resolutions.withLock { $0.removeAll() }
        // Provider choices are this turn's named/interaction/focused signals.
        providerSelection.withLock { $0 = nil }
        // Embedding memo is this turn's utterance. See `semanticSkillAffinityCache`.
        semanticSkillAffinityCache.withLock { $0 = nil }
        // Surface referent for this turn — same lifetime as the other memos.
        surfaceReferent.withLock { $0 = .currentLiveSelection }
        // Demoted, not dropped — see `TurnOfferLedger`. Detached routines dispatch across this boundary.
        offerLedger.withLock {
            $0.previous = $0.current
            $0.current = []
            $0.projected = !$0.previous.isEmpty
        }
    }


    private func executionContext() -> AbilityExecutionContext {
        var context = contextProvider()
        context.surfaceReferent = surfaceReferent.withLock { $0 }
        // Utterance provenance for adapters. Set here — the injected provider is built once.
        context.utterance = ambient.utterance()
        return context
    }

    // MARK: - Per-turn application-aware provider selection

    /// Turn provider choices, resolved once from the route and frozen.
    /// PIN: Outside a turn (no route yet) → empty signals = static preference.
    private func turnProviderSelection(
        snapshot: AbilityRuntimeSnapshot
    ) -> ProviderTurnSelection {
        if let memo = providerSelection.withLock({ $0 }) { return memo }
        let route = ambient.route()
        // The words' own applications: the route gate plus the lead.
        var named = Set(route?.gate.applications ?? [])
        if let leadApplicationID = route?.leadApplicationID {
            named.insert(leadApplicationID)
        }
        let interaction = route?.selectionDefinesTurn == true
            ? route?.attention?.applicationID : nil
        let signals = ApplicationProviderSignals(
            namedApplicationIDs: named,
            interactionApplicationID: interaction,
            pinnedApplicationID: nil,
            focusedApplicationID: focusedApplicationID)
        let resolved = ApplicationProviderResolver.resolve(
            snapshot: snapshot, signals: signals,
            // Combined list (native included) so a spoken native-app name hits the mismatch ledger.
            profiles: applicationProfiles)
        // First writer wins; a racer that lost returns the stored choice.
        providerSelection.withLock { memo in
            if memo == nil { memo = resolved }
        }
        return providerSelection.withLock { $0 } ?? resolved
    }

    /// Operation this turn executes for a Skill — provider choice, else the static binding.
    private func turnOperation(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        turnProviderSelection(snapshot: snapshot).operation(for: runtime.skill.id)
            ?? runtime.bindingOperation
    }

    /// `bindingOperation(forInvocation:)` with the turn's provider choice applied.
    private func turnBindingOperation(
        forInvocation name: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> String {
        if let runtime = snapshot.skill(invocationName: name),
           runtime.reference.invocationName == name,
           let operation = turnProviderSelection(snapshot: snapshot)
               .operation(for: runtime.skill.id) {
            return operation
        }
        return snapshot.bindingOperation(forInvocation: name)
    }

    public var hasPendingSkillConfirmation: Bool {
        pendingStore.current() != nil
    }

    public var pendingSkillConfirmationID: UUID? {
        pendingStore.current()?.id
    }

    /// Stored preview, verbatim. `current()` already enforces TTL and the turn window.
    public var pendingSkillConfirmationPreview: String? {
        pendingStore.current()?.preview
    }

    // MARK: - Matching a Skill invocation to a binding

    /// The one matcher — the only place the roster is searched.
    private func resolve(skillName: String) -> AttributedSkillBinding? {
        let query = turnBindingOperation(
            forInvocation: skillName, snapshot: abilitySnapshot).lowercased()
        if let memo = resolutions.withLock({ $0[query] }) {
            return memo.map { attributed[$0] }
        }
        let index = attributed.firstIndex { $0.binding.name == query }
            ?? fuzzyOrder().first { position in
                let name = attributed[position].binding.name
                // Bidirectional: models truncate ("time" → "speak_time") and pad ("read_documents" → "read_document").
                return name.contains(query) || query.contains(name)
            }
        // A miss is cached too: outer optional = resolved this turn; inner = anything answered.
        resolutions.withLock { $0[query] = index }
        return index.map { attributed[$0] }
    }

    /// Bindings a fuzzy match may reach this turn, ordered — indices into `attributed`.
    /// PIN: Pool drops rival workspace worlds and nothing else.
    func placeScope() -> (lead: AmbientPlace, admitted: Set<AmbientPlace>)? {
        guard let owner = focusProvider?() else { return nil }
        // Owner scopes only when this runtime knows it.
        let registration = applications.registration(id: owner)
        guard abilitySnapshot.plugins.applicationProfiles
            .contains(where: { $0.id == owner })
            || registration?.hasEyes == true
        else { return nil }
        let lead: AmbientPlace = registration?.place ?? .application(owner)
        var admitted: Set<AmbientPlace> = [lead]
        admitted.formUnion(admittedPlaceMentions())
        return (lead, admitted)
    }

    /// Places this turn's words re-admit — `AmbientRanker`'s mentions ladder.
    func admittedPlaceMentions() -> Set<AmbientPlace> {
        AmbientRanker.admittedPlaceMentions(
            route: ambient.route(),
            referent: ambient.referent(),
            utterance: ambient.utterance())
    }

    /// True when this binding may appear on a turn scoped by `placeScope()`.
    private func admits(
        owner: String, scope: (lead: AmbientPlace, admitted: Set<AmbientPlace>)?
    ) -> Bool {
        guard let scope, let place = scopedPlace(owner: owner), place.hasEyes
        else { return true }
        return scope.admitted.contains(place)
    }

    /// Owner's place: roster first, then the served-world map a package installed.
    private func place(ofOwner owner: String) -> AmbientPlace? {
        applications.registration(id: owner)?.place
            ?? servedWorlds[owner].map(AmbientPlace.lane)
    }

    private func scopedPlace(owner: String) -> AmbientPlace? {
        applications.registration(id: owner)?.place
    }

    private func fuzzyOrder() -> [Int] {
        let everything = Array(attributed.indices)
        guard let scope = placeScope() else { return everything }
        let eligible = everything.filter { index in
            // Standalone/eyeless bindings stay reachable from everywhere.
            admits(owner: attributed[index].owner, scope: scope)
        }
        // Leading place first among what remains.
        let owner = scope.lead.application ?? scope.lead.world.pluginOwner
        return eligible.filter { attributed[$0].owner == owner }
            + eligible.filter { attributed[$0].owner != owner }
    }

    public func isReadOnly(_ skillName: String) -> Bool {
        // Primitives can read OR mutate depending on their arguments
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return false
        default:
            return resolve(skillName: operation)?.binding.access == .read
        }
    }

    /// Whether this invocation is the screen look.
    /// PIN: A look's summary is the answer — never settle it silently.
    public func isLookSkill(_ skillName: String) -> Bool {
        abilitySnapshot.bindingOperation(forInvocation: skillName) == Self.lookSkillName
    }

    /// Cognitive activation is instruction, not effect — no application touch.
    public func isNonEffectful(_ skillName: String) -> Bool {
        abilitySnapshot.skill(invocationName: skillName)?
            .skill.execution.kind == .cognitive
    }

    /// Binding's `preparesSurface` — staged a surface without delivering the asked-for work.
    public func preparesSurface(_ skillName: String) -> Bool {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        return resolve(skillName: operation)?.binding.preparesSurface == true
    }

    /// Place a called Skill belongs to — dispatcher is the only place that knows.
    public func place(ofSkill skillName: String) -> AmbientPlace? {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return nil
        default:
            guard let owner = resolve(skillName: operation)?.owner, !owner.isEmpty
            else { return nil }
            return applications.registration(id: owner)?.place
        }
    }

    public func world(ofSkill skillName: String) -> AmbientWorld? {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return nil
        default:
            guard let owner = resolve(skillName: operation)?.owner, !owner.isEmpty else { return nil }
            return place(ofOwner: owner)?.world
        }
    }

    /// World's declared targeted read — what a `WorldVeto` redirect names.
    /// PIN: Same table as fetch-first, so the redirect cannot invent a binding.
    public func targetedReadInvocation(
        forWorld world: AmbientWorld
    ) -> (binding: String, parameter: String)? {
        targetedReads[world.pluginOwner]
    }

    /// Fetch-first: leading world's targeted read for `phrase`, same summary the model would see.
    public func readNamedPart(_ phrase: String) async -> String? {
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        // Container the turn named first, then the leading world.
        let owner = ambient.referent()?.place.memoryToken ?? focusProvider?()
        guard !wanted.isEmpty,
              let owner,
              let targeted = targetedReads[owner],
              skillBindings.contains(where: { $0.name == targeted.binding }),
              let arguments = try? JSONSerialization.data(
                withJSONObject: [targeted.parameter: wanted], options: [.sortedKeys]),
              let json = String(data: arguments, encoding: .utf8)
        else { return nil }
        let outcome = await dispatch(name: targeted.binding, argumentsJSON: json)
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// Pre-lane look — `readNamedPart`'s sibling for sight.
    public func wouldServeLook() -> Bool {
        if let owner = focusProvider?(), targetedReads[owner] != nil { return false }
        return skillBindings.contains { $0.name == Self.lookSkillName }
    }

    public func lookAtScreen(_ query: String?) async -> String? {
        guard wouldServeLook() else { return nil }
        var arguments: [String: String] = [:]
        if let query, !query.isEmpty { arguments["query"] = query }
        guard let data = try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let outcome = await dispatch(name: Self.lookSkillName, argumentsJSON: json)
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Locating what a revision is about

    /// Locate, not read — resolve the named part against the leading world's open body.
    /// PIN: One line of this file knows `EditIntent`; other fields stay unused.
    public func locatePassage(_ intent: EditIntent) async -> LocatedPassage? {
        await locatePassage(targets: intent.target, anaphoric: intent.isAnaphoric)
    }

    public func locatePassage(
        _ intent: EditIntent, worldHint: AmbientWorld?
    ) async -> LocatedPassage? {
        await locatePassage(
            targets: intent.target, anaphoric: intent.isAnaphoric,
            worldHint: worldHint)
    }

    /// Locate ladder — stop at the first rung that yields; only the last gives up.
    func locatePassage(
        targets: [String], anaphoric: Bool = false,
        worldHint: AmbientWorld? = nil, now: Date = Date()
    ) async -> LocatedPassage? {
        // Same focus decision the prompt, roster hoist, deposit subject, and pre-read use.
        let recentAnaphoricPassage = anaphoric ? passages.live(at: now).first : nil
        let owner = focusProvider?() ?? worldHint?.pluginOwner
            ?? recentAnaphoricPassage?.place.memoryToken
        guard let owner,
              let verb = targetedEdits[owner],
              // Mirrors `readNamedPart`'s check that the declared binding is really in the catalog
              skillBindings.contains(where: { $0.name == verb.binding }),
              let backing = passageBackings[owner]
        else { return nil }

        // Dictionary lookups so far — worlds with no documents cost nothing and read no body.
        guard let snapshot = await backing.body() else { return nil }

        var wanted = targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // `routedSelectionHandoff`: turn-local snapshot plus the route's own gate.
        if anaphoric,
           let handoff = ambient.routedSelectionHandoff(world: backing.place.world) {
            let selected = handoff.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty { wanted.append(selected) }
        }

        // Recent passage joins as a target rather than short-circuiting the ladder.
        if anaphoric,
           let recent = recentAnaphoricPassage ?? passages.live(at: now)
            .first(where: { $0.place == backing.place }) {
            wanted.append(recent.text)
        }

        // Rungs 1–3. `PassageEditRunner.mint` is the ladder and mint the Skill bindings use.
        for (index, target) in wanted.enumerated() {
            guard case .found(let found) = await PassageEditRunner.mint(
                target: target, in: snapshot, backing: backing,
                registry: passages, ambient: ambient, now: now)
            else { continue }
            return LocatedPassage(
                passage: found.passage, label: found.label, verb: verb,
                widened: index > 0 || Self.chosenForThem(found))
        }

        // Rung 4, then 5.
        return fallbackPassage(in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// True when we chose the span rather than their words matching whole.
    /// PIN: False only for a single candidate on a whole-target rung.
    static func chosenForThem(_ found: PassageEditRunner.Located) -> Bool {
        guard found.confidence == .exact, let rung = found.rung else { return true }
        switch rung {
        case .verbatim, .structural, .normalized: return false
        case .tokenOverlap, .widened:             return true
        }
    }

    /// Rung 4 — named target missed; fall back to where they are (selection, then attention).
    private func fallbackPassage(
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        let units = backing.units(snapshot.text)

        // Source-owned handoff keeps the full AX text.
        // PIN: Not `requiringWritingTarget: true` — that flag killed this rung in production.
        let selected = (ambient.routedSelectionHandoff(
            world: backing.place.world)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty,
           // First occurrence — same as `PassageAttention`'s `range(of:)` anchor.
           let span = PassageWidening.occurrences(of: selected, in: snapshot.text).first {
            let unit = units.first { $0.range == span }
            return mintFallback(
                span: span, kind: unit?.kind ?? .window, label: unit?.label ?? "",
                note: "what you had selected",
                in: snapshot, backing: backing, verb: verb, now: now)
        }

        guard let anchor = PassageEditRunner
                .attention(for: backing.place, ambient: ambient)?
                .anchor(in: snapshot.text),
              let unit = units
                .filter(\.kind.isBlock)
                // Empty span at a unit's upper bound is outside it.
                .filter({ $0.contains(anchor..<anchor) })
                .min(by: { $0.length < $1.length })
        else { return nil }   // RUNG 5. Nothing to gate on; the turn is unchanged.

        return mintFallback(
            span: unit.range, kind: unit.kind, label: unit.label,
            note: "the part you're working in",
            in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// Mint via `PassageRecipes.mintRead` — the one place a read mints a handle.
    private func mintFallback(
        span: Range<Int>,
        kind: PassageUnitKind,
        label: String,
        note: String,
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        guard let passage = PassageRecipes.mintRead(
            place: backing.place,
            documentKey: snapshot.documentKey,
            documentTitle: snapshot.documentTitle,
            body: snapshot.text,
            range: span,
            kind: kind,
            locatorNote: note,
            registry: passages,
            at: now)
        else { return nil }
        // Always widened — we chose this span because nothing they named was found.
        return LocatedPassage(passage: passage, label: label, verb: verb, widened: true)
    }

    /// Lane timing log — every dispatch (model, deterministic press, confirm replay).
    static let timingLog = Logger(subsystem: "nyc.rao.mary", category: "lanes")

    /// Dispatch chokepoint — model, lane press, and confirmation replay all enter here.
    public func dispatch(
        name: String, argumentsJSON: String, runID: String? = nil
    ) async -> SkillOutcome {
        let startedAt = Date()
        let dispatchStart = DispatchTime.now()
        // Read reference before dispatch — a dispatch can change provider selection.
        let turnReference = skillReference(for: name)
        let confirmationID = pendingStore.current()?.id

        // One identity for the whole act — chip, ledger, episode, and Stop share it.
        let identity = runID ?? UUID().uuidString
        let outcome = await RunContext.$runID.withValue(identity) {
            await dispatchCore(name: name, argumentsJSON: argumentsJSON)
        }

        let record = BehavioralActionRecord(
            outcome: outcome,
            intention: name,
            argumentsJSON: Self.canonicalArguments(argumentsJSON),
            reference: turnReference,
            runID: identity,
            // Confirmation thread — park and replay are two episodes, one act.
            confirmationID: confirmationID ?? pendingStore.current()?.id,
            startedAt: startedAt)
        executionLog.record(record)
        behavior?.append(record)
        let totalMs = (DispatchTime.now().uptimeNanoseconds
            &- dispatchStart.uptimeNanoseconds) / 1_000_000
        let line = "dispatch \(name) — total \(totalMs)ms,"
            + " status=\(record.disposition)"
        Self.timingLog.info("\(line, privacy: .public)")
        return outcome
    }

    private func dispatchCore(name: String, argumentsJSON: String) async -> SkillOutcome {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        let operation = turnBindingOperation(forInvocation: name, snapshot: snapshot)
        let invokedRuntimeSkill = snapshot.skill(invocationName: name)
        // Exact name may stay exact without crossing applications.
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           invokedRuntimeSkill.reference.invocationName != name,
           let exactBinding = snapshot.compatibleBindings(
               for: invokedRuntimeSkill.skill.id).first(where: {
                   $0.operation == name
               }),
           let exactApplicationID = snapshot.applicationID(
               of: invokedRuntimeSkill,
               binding: exactBinding)?.lowercased() {
            let providerSelection = turnProviderSelection(snapshot: snapshot)
            let frozenApplicationID = providerSelection.choice(
                for: invokedRuntimeSkill.skill.id)?
                .provider?.applicationID?.lowercased()
            // Frozen provider from a lower rung wins; an exact call may not pick the rival.
            let admittedApplicationIDs: Set<String> = frozenApplicationID.map {
                [$0]
            } ?? providerSelection.decisiveApplicationIDs
            if !admittedApplicationIDs.isEmpty,
               !admittedApplicationIDs.contains(exactApplicationID) {
                let profiles = applicationProfiles
                let exactTitle = profiles.first {
                    $0.id.lowercased() == exactApplicationID
                }?.title ?? exactApplicationID
                let admittedTitles = admittedApplicationIDs.map { admitted in
                    profiles.first { $0.id.lowercased() == admitted }?.title
                        ?? admitted
                }.sorted()
                return blockedOutcome(
                    runtime: invokedRuntimeSkill,
                    reason: "the exact \(exactTitle) provider contradicts this turn's frozen application choice (\(admittedTitles.joined(separator: " or "))); use \(invokedRuntimeSkill.reference.invocationName) so the frozen provider can execute")
            }
        }
        // Mismatch abstain — only the provider-neutral invocation is guarded.
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           invokedRuntimeSkill.reference.invocationName == name,
           let mismatch = turnProviderSelection(snapshot: snapshot).mismatch(
               for: invokedRuntimeSkill.skill.id) {
            let escape: String
            if let available = mismatch.availableTitles.first {
                escape = "\(mismatch.availableTitles.joined(separator: " or ")) can — say 'in \(available)' or switch to it to make this change there"
            } else {
                escape = "no installed application currently can"
            }
            return blockedOutcome(
                runtime: invokedRuntimeSkill,
                reason: "\(mismatch.wantedTitle) can't do this yet; \(escape)")
        }
        // Hard facts first, then the offer ledger — permission miss outranks "wasn't offered".
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           let reason = dispatchEligibilityFailure(
               for: invokedRuntimeSkill,
               in: routing,
               snapshot: snapshot) {
            return blockedOutcome(runtime: invokedRuntimeSkill, reason: reason)
        }
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           let reason = offerLedgerFailure(
               for: invokedRuntimeSkill,
               roster: roster) {
            return blockedOutcome(runtime: invokedRuntimeSkill, reason: reason)
        }
        // Built-ins match exactly, before anything else can eat them.
        switch operation {
        case Self.confirmSkillName:
            return await executePending()
        case Self.cancelSkillName:
            let reference = pendingStore.current()?.reference
                ?? snapshot.reference(forInvocation: Self.cancelSkillName)
            pendingStore.clear()
            // Nothing happened, so there is nothing to recall.
            return SkillOutcome(
                ok: true, summary: "Okay, cancelled — nothing was changed.",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: reference)
        default:
            break
        }

        // Schema-executed Skills have no Plugin binding — same eligibility, frozen snapshot.
        if let invokedRuntimeSkill {
            let arguments = Self.stringArguments(fromJSON: argumentsJSON)
            let policy = snapshot.executionPolicy(for: invokedRuntimeSkill.skill)
            let signals = routedSignalSnapshot()
            if let failure = payloadFailure(
                runtime: invokedRuntimeSkill,
                arguments: arguments,
                typedInputs: [:],
                signals: signals,
                policy: policy) {
                return failure
            }
            switch invokedRuntimeSkill.skill.execution.kind {
            case .cognitive:
                let outcome = executeCognitive(
                    runtime: invokedRuntimeSkill,
                    arguments: arguments,
                    snapshot: snapshot,
                    signals: signals)
                return Self.applyingTotemArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: invokedRuntimeSkill,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: executionContext(),
                    signals: signals)
                return Self.applyingTotemArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .binding:
                break
            }
        }

        // Exact name, else fuzzy within this turn's worlds. See `resolve`.
        guard var binding = resolve(skillName: operation)?.binding else {
            return SkillOutcome(ok: false, summary: "There is no command called \(name).")
        }
        let runtimeSkill = invokedRuntimeSkill
            ?? snapshot.skill(bindingOperation: binding.name)
        // Same two gates for a Skill reached by binding name or fuzzy match.
        if let runtimeSkill,
           let reason = dispatchEligibilityFailure(
               for: runtimeSkill,
               in: routing,
               snapshot: snapshot)
               ?? offerLedgerFailure(for: runtimeSkill, roster: roster) {
            return blockedOutcome(runtime: runtimeSkill, reason: reason)
        }
        if let schemaSkill = runtimeSkill?.skill {
            // Portable policy may tighten a local operation, never loosen it.
            if schemaSkill.access == .confirm { binding.access = .write }
            binding.stage = binding.stage || schemaSkill.usesStage
        }
        let reference = runtimeSkill?.reference
            ?? snapshot.reference(forInvocation: binding.name)

        // Native mismatch mirror — abstain when every asserted app is one they cannot serve.
        if runtimeSkill == nil,
           let owner = resolve(skillName: operation)?.owner,
           let ownerPlace = place(ofOwner: owner), ownerPlace.hasEyes {
            let asserted = turnProviderSelection(snapshot: snapshot)
                .decisiveApplicationIDs
            if !asserted.isEmpty, !asserted.contains(owner),
               !admittedPlaceMentions().contains(ownerPlace) {
                let profiles = nativeProfiles
                    + snapshot.plugins.applicationProfiles
                let wanted = profiles.first { asserted.contains($0.id) }?.title
                    ?? asserted.sorted()[0]
                return SkillOutcome(
                    ok: false,
                    summary: "\(ownerPlace.displayName) isn't the application this turn is about — \(wanted) is. Say 'in \(ownerPlace.displayName)' or switch to it to make this change there.",
                    status: .blocked,
                    archivePolicy: .none,
                    skillReference: reference)
            }
        }

        var arguments = Self.stringArguments(fromJSON: argumentsJSON)
        arguments = Self.reconcile(arguments, against: binding.parameters)
        // `type_at_cursor` covers compose and replace-selection — requirement is conditional.
        if binding.name == "type_at_cursor",
           arguments["mode"] == "replace_selection",
           ambient.routedSelectionHandoff(
               requiringWritingTarget: true) == nil {
            return SkillOutcome(
                ok: false,
                summary: "That selection is not the routed writing target for this request, so I did not replace it.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: reference)
        }
        let context = executionContext()
        let policy = runtimeSkill.map { snapshot.executionPolicy(for: $0.skill) }
            ?? .unconstrained
        let signals = routedSignalSnapshot()
        if let runtimeSkill,
           let failure = payloadFailure(
               runtime: runtimeSkill,
               arguments: arguments,
               typedInputs: [:],
               signals: signals,
               policy: policy) {
            return failure
        }

        if binding.access == .write {
            let preview = await previewQuestion(
                binding: binding, arguments: arguments, context: context)
            var deferredContext = context
            if deferredContext.surfaceReferent == .previouslyCreatedSurface {
                deferredContext.surfaceReferent =
                    .previouslyCreatedSurfaceUnavailable
            }
            pendingStore.set(
                skillName: binding.name,
                arguments: arguments,
                preview: preview,
                binding: binding,
                context: deferredContext,
                reference: reference,
                executionPolicy: policy,
                signalSnapshot: signals)
            return SkillOutcome(
                ok: true,
                // Question alone — "nothing has happened yet" is prompt guidance, not tool text.
                summary: "CONFIRM: \(preview)",
                status: .requested,
                archivePolicy: .none,
                skillReference: reference
            )
        }

        return await execute(
            binding: binding,
            arguments: arguments,
            context: context,
            reference: reference,
            runtime: runtimeSkill,
            policy: policy,
            signals: signals)
    }

    // MARK: - Cognitive and workflow execution

    /// Cognitive primitives and schema state machines intentionally keep their internal steps out of memory.
    static func applyingTotemArchivePolicy(
        _ input: SkillOutcome,
        reference: AbilitySkillReference,
        snapshot: AbilityRuntimeSnapshot
    ) -> SkillOutcome {
        guard input.archivePolicy == .none,
              input.status == .succeeded || input.status == .failed,
              snapshot.totemProjectionPlan(for: reference)?.permitsDurableStorage == true
        else { return input }
        var output = input
        output.archivePolicy = .episodic
        return output
    }

    private func executeCognitive(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        typedInputs: [String: ValueEnvelope] = [:],
        signals: SchemaSignalTurnSnapshot
    ) -> SkillOutcome {
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: typedInputs,
            signals: signals,
            policy: policy) {
            return failure
        }
        guard let contract = CognitivePrimitiveCatalog.contract(for: runtime) else {
            return blockedOutcome(
                runtime: runtime,
                reason: "no closed Mary cognitive primitive is registered")
        }
        if let missing = CognitivePrimitiveCatalog.missingRequiredArgument(
            for: contract,
            arguments: arguments) {
            return SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) needs \(missing).",
                status: .blocked,
                archivePolicy: .none,
                skillReference: runtime.reference)
        }
        var summary = CognitivePrimitiveCatalog.activate(
            contract,
            arguments: arguments)
        // compose_draft placement: staged surface, else a writing world the utterance named.
        if contract.primitive == .composeDraft {
            let staged = StagedWritingSurface.shared.fresh()
            // Named writing place — not a compiled editor list (that dropped other apps).
            let namedWriting = ambient.route()?.namedPlaces
                .first(where: { $0.focus == .writing })
            if let clause = CognitivePrimitiveCatalog.composePlacementClause(
                stagedApplicationName: staged.map { $0.spokenName ?? $0.bundleID },
                namedWritingApplication: namedWriting?.displayName) {
                summary += clause
            }
        } else if contract.primitive == .reviseSelection {
            // revise_selection: whether the routed selection is still there to write into.
            if let clause = CognitivePrimitiveCatalog.revisionPlacementClause(
                hasRoutedSelection: ambient.routedSelectionHandoff(
                    requiringWritingTarget: true) != nil) {
                summary += clause
            }
        } else if contract.primitive == .reviseCodeSelection {
            // Code-lane mirror, gated on the predicate that lane's placing Skill uses.
            if let clause = CognitivePrimitiveCatalog.codeRevisionPlacementClause(
                hasRoutedCodeSelection:
                    ambient.routedSelectionHandoff()?.place.focus == .coding) {
                summary += clause
            }
        }
        var typedOutputs: [String: ValueEnvelope] = [:]
        for output in runtime.skill.outputs {
            guard let schema = snapshot.valueTypeSchema(id: output.valueType),
                  schema.shape == .string
            else { continue }
            typedOutputs[output.name] = ValueEnvelope(
                    typeID: output.valueType,
                    schemaVersion: schema.version,
                    value: .string(summary),
                    provenance: .init(operation: runtime.reference.invocationName),
                    privacy: .private)
        }
        let outcome = enforceOutputPayload(
            SkillOutcome(
            ok: true,
            summary: summary,
            archivePolicy: .none,
            skillReference: runtime.reference,
            typedOutputs: typedOutputs),
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    private func executeWorkflow(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int = 0
    ) async -> SkillOutcome {
        guard depth < 8 else {
            return blockedOutcome(
                runtime: runtime,
                reason: "the nested workflow depth exceeded Mary's bound")
        }
        if let reason = workflowExecutionSafetyFailure(
            for: runtime,
            snapshot: snapshot) {
            return blockedOutcome(runtime: runtime, reason: reason)
        }
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: [:],
            signals: signals,
            policy: policy) {
            return failure
        }

        // Packages may shorten the budget, not enlarge Mary's ten-minute ceiling.
        let userCap = ordinarySkillTimeout.withLock { $0 }
        let budget = Self.effectiveWorkflowBudget(
            invocationName: runtime.reference.invocationName,
            packageTimeout: runtime.skill.timeoutSeconds ?? 600,
            policyCap: policy.maximumDurationSeconds ?? 600,
            userCap: userCap)
        let supplementalPorts = workflowSupplementalPorts(
            for: runtime,
            arguments: arguments,
            snapshot: snapshot)
        let worker = Task { [self] in
            await WorkflowStateMachine.run(
                skill: runtime.skill,
                arguments: arguments,
                supplementalPorts: supplementalPorts) { step, ports, originalArguments in
                    await self.executeWorkflowStep(
                        step,
                        owner: runtime,
                        ports: ports,
                        originalArguments: originalArguments,
                        snapshot: snapshot,
                        context: context,
                        signals: signals,
                        depth: depth)
                }
        }
        let runIdentity = registerInFlight { worker.cancel() }
        defer { releaseInFlight(runIdentity) }
        let result = await withTaskCancellationHandler {
            await bounded(budget) { await worker.value }
        } onCancel: {
            worker.cancel()
        }
        worker.cancel()
        // Same rule as `performExecute`: a requested stop is what the record says happened.
        if wasStopRequested(runIdentity) {
            let stopped = SkillOutcome(
                ok: false,
                summary: "You stopped \(runtime.reference.invocationName).",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime, arguments: arguments, outcome: stopped)
            return stopped
        }

        guard let machineResult = result else {
            let timedOut = SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) did not finish within \(Int(budget)) seconds.",
                status: .failed,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime,
                arguments: arguments,
                outcome: timedOut)
            return timedOut
        }
        var outcome = machineResult.outcome
        outcome.skillReference = runtime.reference
        for output in runtime.skill.outputs {
            if let envelope = machineResult.ports[output.name]?.envelope {
                outcome.typedOutputs[output.name] = envelope
            }
        }
        if outcome.status == .deferred || outcome.status == .requested {
            outcome.archivePolicy = .none
        }
        outcome = enforceOutputPayload(
            outcome,
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    private func executeWorkflowStep(
        _ step: WorkflowStepSchema,
        owner: AbilityRuntimeSkill,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int
    ) async -> WorkflowOperationResult {
        if let target = snapshot.skill(invocationName: step.operation) {
            // A validated workflow is already an exact machine route.
            if let reason = dispatchEligibilityFailure(
                for: target,
                in: abilityRoutingContext(),
                snapshot: snapshot) {
                return WorkflowOperationResult(outcome: blockedOutcome(
                    runtime: target,
                    reason: reason))
            }
            let arguments = workflowArguments(
                for: target,
                step: step,
                ports: ports,
                originalArguments: originalArguments)
            switch target.skill.execution.kind {
            case .cognitive:
                let outcome = executeCognitive(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    typedInputs: Dictionary(
                        uniqueKeysWithValues: step.consumes.compactMap { name in
                            ports[name]?.envelope.map { (name, $0) }
                        }),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: context,
                    signals: signals,
                    depth: depth + 1)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .binding:
                guard let operation = target.bindingOperation,
                      var binding = attributed.first(where: {
                          $0.binding.name == operation
                      })?.binding
                else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "its exact adapter implementation disappeared"))
                }
                if target.skill.access == .confirm { binding.access = .write }
                binding.stage = binding.stage || target.skill.usesStage
                guard binding.access != .write else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "a workflow cannot cross a user-confirmation boundary without a declared continuation"))
                }
                let reconciled = Self.reconcile(
                    arguments,
                    against: binding.parameters)
                let typedInputs = Dictionary(
                    uniqueKeysWithValues: step.consumes.compactMap { name in
                        ports[name]?.envelope.map { (name, $0) }
                    })
                let outcome = await execute(
                    binding: binding,
                    arguments: reconciled,
                    typedInputs: typedInputs,
                    context: context,
                    reference: target.reference,
                    runtime: target,
                    policy: snapshot.executionPolicy(for: target.skill),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            }
        }

        guard let contract = CognitivePrimitiveCatalog.contract(
            workflowOperation: step.operation,
            abilityID: owner.ability.id)
        else {
            return WorkflowOperationResult(outcome: SkillOutcome(
                ok: false,
                summary: "Workflow step \(step.id) has no executable operation.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: owner.reference))
        }
        let arguments = workflowArguments(
            for: nil,
            step: step,
            ports: ports,
            originalArguments: originalArguments)
        return WorkflowOperationResult(outcome: SkillOutcome(
            ok: true,
            summary: activateWorkflowPrimitive(
                contract,
                arguments: arguments),
            archivePolicy: .none,
            skillReference: owner.reference))
    }

    private func activateWorkflowPrimitive(
        _ contract: CognitivePrimitiveContract,
        arguments: [String: String]
    ) -> String {
        switch contract.primitive {
        case .retrieveProjectContext:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: false)
        case .searchProjectKnowledge:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: true)
        default:
            return CognitivePrimitiveCatalog.activate(
                contract,
                arguments: arguments)
        }
    }

    /// Concrete Architect retrieval over Mary's source-attributed ambient ledger.
    private func renderProjectFacts(
        arguments: [String: String],
        retainedOnly: Bool
    ) -> String {
        let project = Self.projectName(in: arguments)?.lowercased()
        let requestTokens = Set(
            (arguments["request"] ?? arguments["question"] ?? "")
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init))
        // Same immutable route as prompt assembly — Architect is an Ability path.
        let routedFacts = ambient.route().map { route in
            ambient.facts().filter(route.admitsHeldFact)
        } ?? ambient.facts()
        let candidates = routedFacts.filter { fact in
            if retainedOnly && fact.registration != .askedFor
                && !fact.slot.isRead
                && fact.slot != .project
                && fact.slot != .git {
                return false
            }
            if let project {
                let identity = [fact.subject, fact.content]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                guard identity.contains(project) else { return false }
            }
            guard retainedOnly, !requestTokens.isEmpty else { return true }
            let searchable = "\(fact.subject ?? "") \(fact.content)".lowercased()
            let words = Set(searchable
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
            return !words.isDisjoint(with: requestTokens)
        }
        let selected = candidates
            .sorted { left, right in left.capturedAt > right.capturedAt }
            .prefix(8)
        guard !selected.isEmpty else {
            return retainedOnly
                ? "No matching source-attributed project knowledge is currently held."
                : "No source-attributed live context is currently held for that project."
        }
        return selected.map { fact in
            let subject = fact.subject.map { " · \($0)" } ?? ""
            let content = String(fact.content.prefix(700))
            return "\(fact.world.rawValue)/\(fact.slot.token)\(subject): \(content)"
        }.joined(separator: "\n")
    }

    private static func projectName(in arguments: [String: String]) -> String? {
        if let explicit = arguments["project"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        for key in ["scope", "interaction.project-reference", "request"] {
            guard let text = arguments[key],
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let project = object["project"] as? String,
                  !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return project
        }
        return nil
    }

    /// Adapts the typed workflow ledger onto today's string-dictionary Plugin seam.
    private func workflowArguments(
        for target: AbilityRuntimeSkill?,
        step: WorkflowStepSchema,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String]
    ) -> [String: String] {
        var result = originalArguments
        let consumed = step.consumes.compactMap { name in
            ports[name].map { (name, $0) }
        }
        for (name, port) in consumed { result[name] = port.value }
        guard let target else { return result }

        for (index, input) in target.skill.inputs.enumerated()
        where result[input.name] == nil {
            let typed = consumed.first { $0.1.valueType == input.valueType }
            let positional = index < consumed.count ? consumed[index] : nil
            if let source = typed ?? positional {
                result[input.name] = source.1.value
            }
        }

        for (index, parameter) in target.skill.modelExposure.parameters.enumerated()
        where result[parameter.name] == nil {
            if target.skill.inputs.count == 1,
               let input = target.skill.inputs.first,
               let value = result[input.name] {
                result[parameter.name] = value
            } else if index < consumed.count {
                result[parameter.name] = consumed[index].1.value
            }
        }
        return result
    }

    private func workflowSupplementalPorts(
        for runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot
    ) -> [String: WorkflowPortValue] {
        var ports: [String: WorkflowPortValue] = [:]
        let signals = routedSignalSnapshot()
        for interaction in signals.interactions(declaredBy: runtime.skill) {
            ports[interaction.reference.schemaID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(interaction.value.value),
                valueType: interaction.value.typeID,
                envelope: interaction.value,
                producerStepID: nil)
        }
        for interactionID in runtime.skill.requirements.optionalInteractions
        where ports[interactionID.rawValue] == nil {
            guard let interaction = snapshot.interactionSchema(id: interactionID),
                  let valueSchema = snapshot.valueTypeSchema(id: interaction.valueType),
                  let envelope = Self.structuredEnvelope(
                      arguments: arguments,
                      schema: valueSchema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName,
                      interactionID: interactionID)
            else { continue }
            ports[interactionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(envelope.value),
                valueType: envelope.typeID,
                envelope: envelope,
                producerStepID: nil)
        }
        for perceptionID in runtime.skill.requirements.perceptions
            + runtime.skill.requirements.optionalPerceptions {
            guard let perception = signals.perceptions.first(where: {
                $0.reference.schemaID == perceptionID
            }) else { continue }
            ports[perceptionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(perception.value.value),
                valueType: perception.value.typeID,
                envelope: perception.value,
                producerStepID: nil)
        }

        for (index, input) in runtime.skill.inputs.enumerated() {
            let projectedName = index < runtime.skill.modelExposure.parameters.count
                ? runtime.skill.modelExposure.parameters[index].name : input.name
            guard let value = arguments[input.name] ?? arguments[projectedName],
                  let schema = snapshot.valueTypeSchema(id: input.valueType),
                  let envelope = Self.legacyEnvelope(
                      value,
                      schema: schema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName)
                    ?? Self.structuredEnvelope(
                        arguments: arguments,
                        schema: schema,
                        registry: snapshot.valueTypeSchemas,
                        operation: runtime.reference.invocationName)
            else { continue }
            ports[input.name] = WorkflowPortValue(
                value: value,
                valueType: input.valueType,
                envelope: envelope,
                producerStepID: nil)
        }
        return ports
    }

    private static func legacyEnvelope(
        _ value: String,
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String
    ) -> ValueEnvelope? {
        let payload: MaryValue
        switch schema.shape {
        case .string, .enumeration:
            payload = .string(value)
        case .boolean:
            guard let parsed = Bool(value.lowercased()) else { return nil }
            payload = .boolean(parsed)
        case .integer:
            guard let parsed = Int64(value) else { return nil }
            payload = .integer(parsed)
        case .number:
            guard let parsed = Double(value), parsed.isFinite else { return nil }
            payload = .number(parsed)
        case .object, .array:
            guard let data = value.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(MaryValue.self, from: data)
            else { return nil }
            payload = parsed
        case .data:
            guard let data = Data(base64Encoded: value) else { return nil }
            payload = .data(data)
        }
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: payload,
            provenance: .init(operation: operation),
            privacy: .private)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredEnvelope(
        arguments: [String: String],
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String,
        interactionID: InteractionID? = nil
    ) -> ValueEnvelope? {
        let schemas = Dictionary(
            registry.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard let value = structuredValue(
            arguments: arguments,
            schema: schema,
            schemas: schemas)
        else { return nil }
        let project = arguments["project"]
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: value,
            scope: SourceScope(projectID: project),
            provenance: .init(
                operation: operation,
                interactionID: interactionID),
            privacy: .sensitive)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredValue(
        arguments: [String: String],
        schema: ValueTypeSchema,
        schemas: [ValueTypeID: ValueTypeSchema]
    ) -> MaryValue? {
        if schema.shape != .object {
            guard let text = arguments[schema.id.rawValue]
                ?? arguments[schema.id.rawValue.split(separator: ".").last.map(String.init) ?? ""]
            else { return nil }
            return primitiveValue(text, shape: schema.shape)
        }
        var fields: [String: MaryValue] = [:]
        for field in schema.fields {
            guard let fieldSchema = schemas[field.valueType] else { return nil }
            guard let text = arguments[field.name] else {
                if field.required { return nil }
                continue
            }
            guard let value = primitiveValue(text, shape: fieldSchema.shape) else {
                return nil
            }
            fields[field.name] = value
        }
        return .object(fields)
    }

    private static func primitiveValue(
        _ text: String,
        shape: ValueShape
    ) -> MaryValue? {
        switch shape {
        case .string, .enumeration: return .string(text)
        case .boolean: return Bool(text.lowercased()).map(MaryValue.boolean)
        case .integer: return Int64(text).map(MaryValue.integer)
        case .number:
            guard let value = Double(text), value.isFinite else { return nil }
            return .number(value)
        case .object, .array:
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MaryValue.self, from: data)
        case .data:
            return Data(base64Encoded: text).map(MaryValue.data)
        }
    }

    private static func legacyString(_ value: MaryValue) -> String {
        switch value {
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .null: return "null"
        case .object, .array, .data:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private func recordSchemaExecution(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        outcome: SkillOutcome
    ) {
        // Recording lives in `dispatch` — one record per act, refusals included.
        _ = arguments
        _ = outcome
    }

    /// Preview-question budget — the second bounded wait; nothing has run yet.
    static let previewBudget: TimeInterval = 15

    private func previewQuestion(
        binding: SkillBinding,
        arguments: [String: String],
        context: AbilityExecutionContext
    ) async -> String {
        let generic = "About to run \(binding.name). Should I go ahead?"
        guard let previewProvider = binding.confirmationPreview else { return generic }
        let described = await bounded(Self.previewBudget) {
            await previewProvider(arguments, context)
        }
        return described ?? generic
    }

    // MARK: - Primitives

    private func executePending() async -> SkillOutcome {
        guard let pending = pendingStore.take() else {
            return SkillOutcome(
                ok: false,
                summary: "There's nothing waiting for confirmation — it may have expired. Ask me again.")
        }
        guard let binding = pending.binding else {
            return SkillOutcome(
                ok: false,
                summary: "The confirmed Skill no longer has a frozen binding.",
                archivePolicy: .none,
                skillReference: pending.reference)
        }
        return await execute(
            binding: binding,
            arguments: pending.arguments,
            context: pending.context,
            reference: pending.reference,
            policy: pending.executionPolicy,
            signals: pending.signalSnapshot)
    }

    // Raw machine primitives are not in this cut.

    // MARK: - Skill execution

    /// Direct path and confirmed replay funnel here — one log row per real binding run.
    private func execute(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext,
        reference: AbilitySkillReference,
        runtime: AbilityRuntimeSkill? = nil,
        policy: CapabilityExecutionPolicy = .unconstrained,
        signals: SchemaSignalTurnSnapshot = .empty
    ) async -> SkillOutcome {
        if let runtime,
           let failure = payloadFailure(
               runtime: runtime,
               arguments: arguments,
               typedInputs: typedInputs,
               signals: signals,
               policy: policy) {
            return failure
        }
        // Bracket before the write — refresh assumes one contiguous caret insertion.
        let bracket = await unroutedWriteBracket(binding)
        var outcome = await performExecute(
            binding: binding,
            arguments: arguments,
            typedInputs: typedInputs,
            context: context,
            maximumDurationSeconds: policy.maximumDurationSeconds)
        outcome = enforceOutputPayload(
            outcome,
            reference: reference,
            policy: policy)
        outcome.skillReference = outcome.skillReference ?? reference
        let owner = ownerID(bindingName: binding.name)
        // See `recordSchemaExecution`: the chokepoint owns the ledger.
        registerRead(binding: binding, owner: owner, arguments: arguments, outcome: outcome)
        if outcome.ok, let bracket {
            await refreshPassages(after: bracket)
        }
        return outcome
    }

    /// Canonical machine payload measured at the last boundary before an adapter or cognitive primitive can observe it.
    private struct MeasuredSkillInput: Encodable {
        var arguments: [String: String]
        var typedInputs: [String: ValueEnvelope]
        var interactions: [ValueEnvelope]
        var perceptions: [ValueEnvelope]
    }

    private struct MeasuredSkillOutput: Encodable {
        var summary: String
        var passageHandle: String?
        var typedOutputs: [String: ValueEnvelope]
    }

    private func payloadFailure(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope],
        signals: SchemaSignalTurnSnapshot,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome? {
        guard let maximum = policy.maximumPayloadBytes else { return nil }
        let payload = MeasuredSkillInput(
            arguments: arguments,
            typedInputs: typedInputs,
            interactions: signals.interactions(declaredBy: runtime.skill).map(\.value),
            perceptions: signals.perceptions(declaredBy: runtime.skill).map(\.value))
        guard let bytes = Self.canonicalByteCount(payload), bytes <= maximum else {
            return SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) was blocked because its typed input exceeded the \(maximum)-byte Capability limit.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: runtime.reference)
        }
        return nil
    }

    private func enforceOutputPayload(
        _ outcome: SkillOutcome,
        runtime: AbilityRuntimeSkill,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome {
        enforceOutputPayload(
            outcome,
            reference: runtime.reference,
            policy: policy)
    }

    private func enforceOutputPayload(
        _ outcome: SkillOutcome,
        reference: AbilitySkillReference,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome {
        guard let maximum = policy.maximumPayloadBytes else { return outcome }
        let payload = MeasuredSkillOutput(
            summary: outcome.summary,
            passageHandle: outcome.passageHandle,
            typedOutputs: outcome.typedOutputs)
        guard let bytes = Self.canonicalByteCount(payload), bytes <= maximum else {
            return SkillOutcome(
                ok: outcome.ok && Self.isMutation(policy.effect),
                summary: outcome.ok && Self.isMutation(policy.effect)
                    ? "\(reference.displayLabel) completed, but Mary omitted its oversized result at the \(maximum)-byte Capability boundary."
                    : "\(reference.displayLabel) returned more than its \(maximum)-byte Capability limit, so Mary discarded the result.",
                status: outcome.ok && Self.isMutation(policy.effect) ? .succeeded : .failed,
                archivePolicy: .none,
                foundNothing: false,
                passageHandle: nil,
                skillReference: reference,
                typedOutputs: [:])
        }
        return outcome
    }

    private static func canonicalByteCount<Value: Encodable>(_ value: Value) -> Int? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value).count
    }

    private static func isMutation(_ effect: CapabilityEffect) -> Bool {
        switch effect {
        case .reversibleMutation, .mutation, .destructive, .externalCommunication:
            return true
        case .none, .read:
            return false
        }
    }

    /// Caret write in flight: world it lands in, and the body one instant before.
    private struct UnroutedWriteBracket {
        let backing: PassageBacking
        let before: BodySnapshot
    }

    /// Before-body for an unrouted write, or nil when nothing here is worth protecting.
    private func unroutedWriteBracket(_ binding: SkillBinding) async -> UnroutedWriteBracket? {
        guard binding.unroutedWrite,
              let owner = focusProvider?(),
              let backing = passageBackings[owner],
              backing.canWrite,
              passages.live().contains(where: { $0.place == backing.place }),
              let before = await backing.body()
        else { return nil }
        return UnroutedWriteBracket(backing: backing, before: before)
    }

    /// Re-aim handles after an unrouted write shifted the body under them.
    private func refreshPassages(after bracket: UnroutedWriteBracket) async {
        guard let after = await bracket.backing.body(),
              after.hash != bracket.before.hash else { return }
        // Injected stores — `PassageRefresh.after` reports the count.
        _ = PassageRefresh.after(
            before: bracket.before, after: after, place: bracket.backing.place,
            registry: passages, ambient: ambient)
    }

    /// A successful read becomes an ambient fact. Gates here are existing doctrine.
    private func registerRead(
        binding: SkillBinding, owner: String,
        arguments: [String: String], outcome: SkillOutcome
    ) {
        guard binding.access == .read, outcome.ok, !outcome.deferred, !outcome.foundNothing,
              // Adapter already filed a richer fact — skip a duplicate generic one.
              !outcome.ambientDeposited,
              let place = placeOfRead(outcome: outcome, owner: owner),
              let fact = AmbientBridge.readFact(
                world: place.world,
                application: place.application,
                phrase: readPhrase(binding: binding, owner: owner, arguments: arguments),
                summary: outcome.summary,
                document: documentOfRead(outcome: outcome),
                passageHandle: outcome.passageHandle)
        else { return }
        ambient.register(fact)
        if case .namedRead(let document, _) = fact.slot,
           let document,
           !document.isEmpty {
            // By place, not world — registered-app reads stamp `other_apps:<id>`.
            containers.noteEvidence(
                place: fact.place,
                key: document,
                .read,
                at: fact.capturedAt)
        }
    }

    /// Document a read's fact is about — from the minted passage, else nil.
    private func documentOfRead(outcome: SkillOutcome) -> String? {
        guard let handle = outcome.passageHandle,
              case .live(let passage) = passages.resolve(handle)
        else { return nil }
        return passage.documentKey
    }

    /// Place a read's fact belongs to — minted passage, else the owning plugin.
    /// PIN: Reads place off the registry, not the binding.
    private func placeOfRead(
        outcome: SkillOutcome, owner: String
    ) -> AmbientPlace? {
        if let handle = outcome.passageHandle,
           case .live(let passage) = passages.resolve(handle) {
            return passage.place
        }
        return place(ofOwner: owner)
    }

    /// Phrase the read targeted — slot key so a re-read supersedes.
    private func readPhrase(
        binding: SkillBinding, owner: String, arguments: [String: String]
    ) -> String {
        if let parameter = targetedReads[owner]?.parameter,
           let value = arguments[parameter]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        // No key sniffing — used to guess the phrase from document/file/title args.
        return binding.name
    }

    private func ownerID(bindingName: String) -> String {
        let owner = attributed.first { $0.binding.name == bindingName }?.owner ?? ""
        return owner.isEmpty ? "mac" : owner
    }

    /// The turn's arguments, canonically ordered.
    static func canonicalArguments(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: canonical, encoding: .utf8)
        else { return argumentsJSON }
        return text
    }

    private static func encodeArguments(_ arguments: [String: String]) -> String? {
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - The dispatch budget

    /// Default wait before the funnel stops, for bindings that do not name their own.
    /// PIN: A universal cap must not kill a real build.
    static let defaultSkillBudget: TimeInterval = 75

    /// The Skill bindings that legitimately outlive the default
    static let skillBudgets: [String: TimeInterval] = [
        "run_tests":    330,   // Subprocess.run(timeout: 300) — `swift test`
        "build_check":  330,   // BuildVerifier's `swift build`, the same 300
        "complete_coding_change": 280, // above Vibe's 240 s session cap
        "run_shortcut": 150,   // Subprocess.run(timeout: 120) — `shortcuts run`
        "zip_folder":   150,   // Subprocess.run(timeout: 120) — `ditto -c -k`
    ]

    public static let ordinarySkillTimeoutMinimum: TimeInterval = 1
    public static let ordinarySkillTimeoutMaximum: TimeInterval = 10
    public static let ordinarySkillTimeoutDefault: TimeInterval = 2

    public static func clampedOrdinarySkillTimeout(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, ordinarySkillTimeoutMinimum), ordinarySkillTimeoutMaximum)
    }

    /// Ordinary bindings take `userCap`; named long jobs keep `declared`.
    public static func effectiveBudget(
        bindingName: String,
        declared: TimeInterval,
        userCap: TimeInterval,
        maximumDurationSeconds: TimeInterval? = nil
    ) -> TimeInterval {
        let capped: TimeInterval
        if skillBudgets[bindingName] != nil {
            capped = declared
        } else {
            capped = min(declared, clampedOrdinarySkillTimeout(userCap))
        }
        return min(capped, maximumDurationSeconds ?? capped)
    }

    public static func effectiveWorkflowBudget(
        invocationName: String,
        packageTimeout: TimeInterval,
        policyCap: TimeInterval,
        userCap: TimeInterval
    ) -> TimeInterval {
        let budget = min(min(packageTimeout, 600), policyCap)
        if skillBudgets[invocationName] != nil { return budget }
        return min(budget, clampedOrdinarySkillTimeout(userCap))
    }

    static func budget(for binding: SkillBinding) -> TimeInterval {
        skillBudgets[binding.name] ?? defaultSkillBudget
    }

    private let ordinarySkillTimeout = OSAllocatedUnfairLock<TimeInterval>(
        initialState: ordinarySkillTimeoutDefault)

    public func setOrdinarySkillTimeout(_ seconds: TimeInterval) {
        ordinarySkillTimeout.withLock { $0 = Self.clampedOrdinarySkillTimeout(seconds) }
    }

    /// Test-only budget scale — same reason as `MaryBrain`'s watchdog scale.
    private let budgetScale = OSAllocatedUnfairLock<Double>(initialState: 1)

    func setBudgetScaleForTesting(_ scale: Double) {
        budgetScale.withLock { $0 = scale }
    }

    /// Binding funnel and deadline — direct path and confirmed replay both enter here.
    private func performExecute(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext,
        maximumDurationSeconds: TimeInterval? = nil
    ) async -> SkillOutcome {
        let scale = budgetScale.withLock { $0 }
        let declaredBudget = Self.budget(for: binding)
        let userCap = ordinarySkillTimeout.withLock { $0 }
        let unscaledBudget = Self.effectiveBudget(
            bindingName: binding.name,
            declared: declaredBudget,
            userCap: userCap,
            maximumDurationSeconds: maximumDurationSeconds)
        let budget = unscaledBudget * scale
        var boundedContext = context
        boundedContext.deadline = Date().addingTimeInterval(budget)
        // Hold the worker — `bounded` uses an unstructured `Task` that inherits neither cancel nor identity.
        let worker = Task {
            await Self.run(
                binding: binding,
                arguments: arguments,
                typedInputs: typedInputs,
                context: boundedContext)
        }
        // Stop-button handle — register before the wait, release after.
        let runIdentity = registerInFlight { worker.cancel() }
        defer { releaseInFlight(runIdentity) }
        let executeStart = DispatchTime.now()
        let outcome = await withTaskCancellationHandler {
            await bounded(budget) { await worker.value }
        } onCancel: {
            worker.cancel()
        }
        worker.cancel()
        let wasStopped = wasStopRequested(runIdentity)
        let executeMs = (DispatchTime.now().uptimeNanoseconds
            &- executeStart.uptimeNanoseconds) / 1_000_000
        let executeLine = "execute \(binding.name) — \(executeMs)ms"
            + (outcome == nil ? " (BUDGET EXPIRED at \(Int(unscaledBudget))s)" : "")
            + (wasStopped ? " (STOPPED)" : "")
        Self.timingLog.info("\(executeLine, privacy: .public)")
        // Stopped call says so, whatever the binding returned. Cancel is a request, not a guarantee.
        if wasStopped {
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "You stopped \(binding.name).",
                    status: .cancelled),
                binding)
        }
        guard let outcome else {
            // Honest timeout sentence, never silence — `BoundedWait`'s rule.
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "\(binding.name) didn't finish within \(Int(unscaledBudget)) seconds — whatever it drives may be busy or mid-sync. Ask me again in a moment."),
                binding)
        }
        return outcome
    }

    /// The binding itself, exactly as it ran before the deadline existed.
    private static func run(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope],
        context: AbilityExecutionContext
    ) async -> SkillOutcome {
        // Stage Skills preempt the current stage holder first.
        if binding.stage {
            await StageArbiter.shared.preemptForNewClaim()
        }
        do {
            switch binding.backing {
            case .native(let implementation):
                return hinted(try await implementation(arguments, context), binding)
            case .typedNative(let implementation):
                let result = try await implementation(TypedSkillInvocation(
                    arguments: arguments,
                    inputs: typedInputs,
                    context: context))
                var outcome = result.outcome
                outcome.typedOutputs.merge(result.outputs) { _, typed in typed }
                return hinted(outcome, binding)
            }
        } catch {
            return hinted(
                SkillOutcome(
                    ok: false,
                    summary: "\(binding.name) failed: \(error.localizedDescription)"),
                binding)
        }
    }

    /// Append `spokenFailureHint` on every failure that does not already contain it.
    private static func hinted(_ outcome: SkillOutcome, _ binding: SkillBinding) -> SkillOutcome {
        guard !outcome.ok,
              let hint = binding.spokenFailureHint,
              !outcome.summary.contains(hint)
        else { return outcome }
        var spoken = outcome
        spoken.summary += " — \(hint)"
        return spoken
    }

    // MARK: - Argument tolerance (ported verbatim)

    /// Adopt a drifted param name ("project_name" for "project") under the declared name.
    static func reconcile(
        _ arguments: [String: String],
        against parameters: [ModelSkillSchema.Parameter]
    ) -> [String: String] {
        var result = arguments
        // A key that is itself a declared parameter is never a loose spelling of another.
        let declared = Set(parameters.map { $0.name.lowercased() })
        // Declared aliases first, matched exactly — loose containment stole sibling values.
        let byLowercasedKey = Dictionary(
            arguments.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        for parameter in parameters where result[parameter.name] == nil {
            for alias in parameter.aliases {
                let candidate = alias.lowercased()
                // An alias that is itself a declared parameter belongs to that one.
                guard !declared.contains(candidate) else { continue }
                if let value = byLowercasedKey[candidate] {
                    result[parameter.name] = value
                    break
                }
            }
        }
        for parameter in parameters where result[parameter.name] == nil {
            let want = parameter.name.lowercased()
            // Sorted — `Dictionary.first(where:)` has no order; loose ties used to flip.
            if let (_, value) = arguments.sorted(by: { $0.key < $1.key })
                .first(where: { key, _ in
                    let have = key.lowercased()
                    guard !declared.contains(have) else { return false }
                    return have.contains(want) || want.contains(have)
                }) {
                result[parameter.name] = value
            }
        }
        return result
    }

    /// JSON args → strings. Numbers and bools stringify so a loose model still dispatches.
    static func stringArguments(fromJSON json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: result[key] = string
            case let bool as Bool: result[key] = bool ? "true" : "false"
            case let number as NSNumber: result[key] = number.stringValue
            case let array as [Any]:
                if JSONSerialization.isValidJSONObject(array),
                   let data = try? JSONSerialization.data(
                       withJSONObject: array, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            case let dictionary as [String: Any]:
                if JSONSerialization.isValidJSONObject(dictionary),
                   let data = try? JSONSerialization.data(
                       withJSONObject: dictionary, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            default: break
            }
        }
        return result
    }
}
