//
//  AbilityRuntime+Resolve.swift
//  MaryBrain
//
//  WHAT: Matching a Skill invocation to an installed binding,
//        and what may be reached from where the user is.
//  IN:   invocation name + this turn's place scope
//  OUT:  the attributed binding, and the facts callers ask about it
//  PIN:  The one matcher — the only place the roster is searched. The fuzzy
//        pool drops rival workspace worlds and nothing else.
//
import Foundation

extension AbilityRuntime {

    // MARK: - Matching a Skill invocation to a binding

    /// The one matcher — the only place the roster is searched.
    func resolve(skillName: String) -> AttributedSkillBinding? {
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
            route: world.store.route(),
            referent: world.store.referent(),
            utterance: world.store.utterance())
    }

    /// True when this binding may appear on a turn scoped by `placeScope()`.
    func admits(
        owner: String, scope: (lead: AmbientPlace, admitted: Set<AmbientPlace>)?
    ) -> Bool {
        guard let scope, let place = scopedPlace(owner: owner), place.hasEyes
        else { return true }
        return scope.admitted.contains(place)
    }

    /// Owner's place: roster first, then the served-world map a package installed.
    func place(ofOwner owner: String) -> AmbientPlace? {
        applications.registration(id: owner)?.place
            ?? servedAttentions[owner].map(AmbientPlace.lane)
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
        let owner = scope.lead.application ?? scope.lead.attention.pluginOwner
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

    public func attention(ofSkill skillName: String) -> AmbientAttention? {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return nil
        default:
            guard let owner = resolve(skillName: operation)?.owner, !owner.isEmpty else { return nil }
            return place(ofOwner: owner)?.attention
        }
    }

    /// World's declared targeted read — what a `WorldVeto` redirect names.
    /// PIN: Same table as fetch-first, so the redirect cannot invent a binding.
    public func targetedReadInvocation(
        forAttention attention: AmbientAttention
    ) -> (binding: String, parameter: String)? {
        targetedReads[attention.pluginOwner]
    }
}
