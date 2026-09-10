//
//  AbilityRuntime+Schemas.swift
//  MaryBrain
//
//  WHAT: The roster the model is shown this turn.
//  IN:   frozen snapshot + roster arbitration
//  OUT:  ModelSkillSchema list (and its count)
//  PIN:  One projection per Skill. A rival binding materializes only through
//        the turn's provider choice, never as a second schema.
//
import Foundation

extension AbilityRuntime {

    /// ONE TURN-PHASE'S ROSTER, projected once. The schemas the model is
    /// offered, the trace that explains them, and their names are three views
    /// of a single arbitration — and they were three separate arbitrations,
    /// each re-reading the world and re-scoring all 105 Skills to reach the
    /// same verdict. A caller that needs any of them takes all three.
    public struct RosterProjection: Sendable {
        public var schemas: [ModelSkillSchema]
        public var trace: AbilityRosterTrace
        public var names: Set<String>

        public init(
            schemas: [ModelSkillSchema],
            trace: AbilityRosterTrace,
            names: Set<String>? = nil
        ) {
            self.schemas = schemas
            self.trace = trace
            self.names = names ?? Set(schemas.map(\.name))
        }
    }

    /// Every name a Skill call could carry, WITHOUT arbitrating anything —
    /// no world read, no scoring. It is a superset of what this turn offers,
    /// which is exactly what a text sanitizer wants: it only ever strips
    /// tool-call syntax, so a wider name set strips no less than the roster's.
    public var knownSkillNames: Set<String> {
        let snapshot = abilitySnapshot
        var names: Set<String> = [Self.confirmSkillName, Self.cancelSkillName]
        for runtime in snapshot.skills where runtime.skill.modelExposure.enabled {
            names.insert(runtime.reference.invocationName)
        }
        for item in attributed { names.insert(item.binding.name) }
        return names
    }

    public var schemas: [ModelSkillSchema] { projectRoster().schemas }

    /// How many Skills this turn exposes. Same projection, counted — the
    /// separate arithmetic this used to run could disagree with the schemas
    /// actually offered, because only the projection knows that a cognitive
    /// Skill with no registered primitive drops out.
    public var schemaCount: Int { projectRoster().schemas.count }

    public func projectRoster() -> RosterProjection {
        // THE TURN'S INPUTS, READ ONCE, IN ORDER. Everything below is a pure
        // function of these four.
        let snapshot = abilitySnapshot
        let signals = routedSignalSnapshot()
        let routing = abilityRoutingContext(snapshot: snapshot, signals: signals)
        let roster = rosterArbitration(
            snapshot: snapshot, context: routing, signals: signals)
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
        // Read once per binding, not twice per comparison.
        var ranked: [(offset: Int, element: AttributedSkillBinding, preference: Int)] = []
        ranked.reserveCapacity(ordered.count)
        for (offset, element) in ordered.enumerated() {
            let preference = snapshot.skill(bindingOperation: element.binding.name)?
                .skill.routing.preference ?? 0
            ranked.append((offset: offset, element: element, preference: preference))
        }
        ranked.sort { lhs, rhs in
            lhs.preference == rhs.preference
                ? lhs.offset < rhs.offset
                : lhs.preference > rhs.preference
        }
        ordered = ranked.map(\.element)
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
        let names = Set(result.map(\.name))
        let shouldLog = codingRosterLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        if shouldLog {
            TurnCircuitLog.rosterExposed(
                snapshot: snapshot,
                roster: roster,
                scope: scope,
                exposed: names)
        }
        return RosterProjection(schemas: result, trace: roster.trace, names: names)
    }

    /// Project the portable Skill schema onto the provider-neutral callable contract.
    private func projectedSchema(
        for binding: SkillBinding,
        snapshot: AbilityRuntime.Snapshot,
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
        snapshot: AbilityRuntime.Snapshot
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
}
