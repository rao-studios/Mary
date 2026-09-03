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
                exposed: Set(result.map(\.name)))
        }
        return result
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
