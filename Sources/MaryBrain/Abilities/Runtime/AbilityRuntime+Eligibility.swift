//
//  AbilityRuntime+Eligibility.swift
//  MaryBrain
//
//  WHAT: Every gate between a named Skill and its execution.
//  IN:   runtime Skill + this turn's routing context
//  OUT:  nil to admit, else the sentence saying why not
//  PIN:  Closed arbitration starts from the projection gate's safe set and
//        can only REMOVE Skills, never add one back.
//
import Foundation

extension AbilityRuntime {

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

    func dispatchEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntime.Snapshot
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

    /// What may be offered — executable set, narrowed by relevance.
    /// PIN: Pre-arbitration gate; input diet unchanged by later filters.
    private func routingEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext
    ) -> String? {
        if context.usesEmbeddingRoster {
            guard context.semanticSkillAffinity[runtime.skill.id] != nil else {
                return "does not match this turn's embedding roster"
            }
            return nil
        }
        // THE WORDS, OR THE SURFACE. An Ability is admitted lexically either
        // by its routing policy (which surfaces are in view) or because the
        // utterance names it — the latter used to live as `utteranceToken`
        // arms inside the policy itself, a second copy of the trigger list
        // that could disagree with it. The triggers are now the only copy.
        if !AbilityRoutingEvaluator.isEligible(runtime.ability.routing, in: context),
           !context.requestedAbilities.contains(runtime.ability.id) {
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
        snapshot: AbilityRuntime.Snapshot
    ) -> String? {
        dispatchEligibilityFailure(for: runtime, in: context, snapshot: snapshot)
            ?? routingEligibilityFailure(for: runtime, in: context)
    }

    /// Record the roster as projected, before place-scope and one-projection filters.
    /// PIN: Pre-filter set.
    func recordProjectedRoster(_ roster: AbilityRosterArbitration) {
        offerLedger.withLock {
            $0.projected = true
            $0.current.formUnion(roster.selectedKeys)
        }
    }

    /// Was this Skill offered this turn? The roster's one authorization claim.
    func offerLedgerFailure(
        for runtime: AbilityRuntimeSkill,
        roster: AbilityRosterArbitration
    ) -> String? {
        // MARY'S OWN PRE-READ IS NOT A MODEL INVOCATION. See `RuntimeRead`.
        if RuntimeRead.isFetchFirst { return nil }
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

    func rosterArbitration(
        snapshot: AbilityRuntime.Snapshot,
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
    func workflowExecutionSafetyFailure(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntime.Snapshot,
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

    func blockedOutcome(
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
}
