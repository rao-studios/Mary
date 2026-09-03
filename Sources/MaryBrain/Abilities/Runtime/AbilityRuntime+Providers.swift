//
//  AbilityRuntime+Providers.swift
//  MaryBrain
//
//  WHAT: Which application provides a Skill this turn.
//  IN:   route gate / interaction / focus / settled habit
//  OUT:  a frozen ProviderTurnSelection, and the operation it names
//  PIN:  Resolved ONCE per turn and frozen. Outside a turn there is no route,
//        so empty signals fall through to the static preference.
//
import Foundation

extension AbilityRuntime {

    // MARK: - Per-turn application-aware provider selection

    /// Turn provider choices, resolved once from the route and frozen.
    /// PIN: Outside a turn (no route yet) → empty signals = static preference.
    func turnProviderSelection(
        snapshot: AbilityRuntime.Snapshot
    ) -> ProviderTurnSelection {
        if let memo = providerSelection.withLock({ $0 }) { return memo }
        let route = world.store.route()
        // The words' own applications: the route gate plus the lead.
        var named = Set(route?.gate.applications ?? [])
        if let leadApplicationID = route?.leadApplicationID {
            named.insert(leadApplicationID)
        }
        let interaction = route?.selectionDefinesTurn == true
            ? route?.world?.applicationID : nil
        let ledger = applicationHabitLedger.withLock { $0 }
        let utterance = world.store.utterance()
        let signals = ApplicationProviderSignals(
            namedApplicationIDs: named,
            interactionApplicationID: interaction,
            pinnedApplicationID: nil,
            focusedApplicationID: focusedApplicationID,
            // Only a settled habit — `resolve` reports `.habitual` solely when
            // one player leads the decayed tally, so a cold start falls
            // through to the declared preference rung below.
            habitualApplicationID: { [snapshot] abilityID in
                guard let skill = snapshot.skills.first(where: {
                    $0.ability.id == abilityID
                }) else { return nil }
                let verdict = ExpertiseResolution.resolve(
                    for: skill, snapshot: snapshot,
                    utterance: utterance, ledger: ledger)
                guard verdict?.isHabitual == true else { return nil }
                return verdict?.chosen?.applicationID
            })
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
    func turnOperation(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntime.Snapshot
    ) -> String? {
        turnProviderSelection(snapshot: snapshot).operation(for: runtime.skill.id)
            ?? runtime.bindingOperation
    }

    /// `bindingOperation(forInvocation:)` with the turn's provider choice applied.
    func turnBindingOperation(
        forInvocation name: String,
        snapshot: AbilityRuntime.Snapshot
    ) -> String {
        if let runtime = snapshot.skill(invocationName: name),
           runtime.reference.invocationName == name,
           let operation = turnProviderSelection(snapshot: snapshot)
               .operation(for: runtime.skill.id) {
            return operation
        }
        return snapshot.bindingOperation(forInvocation: name)
    }
}
