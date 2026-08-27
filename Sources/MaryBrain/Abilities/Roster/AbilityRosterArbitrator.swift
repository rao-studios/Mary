import MaryFoundation
import Foundation

/// Stable identity for one Skill in an activated package. `SkillID` values are
/// conventionally namespaced, but package identity remains part of router state
/// so two independently imported packages can never suppress one another by
/// accidentally choosing the same string.
/// Result of the closed roster stage. Callers use the selected key set as the
/// single authority for schema projection, schema counts, and direct dispatch.
struct AbilityRosterArbitration: Sendable {
    var selectedKeys: Set<AbilityRosterSkillKey>
    var trace: AbilityRosterTrace

    func contains(_ runtime: AbilityRuntimeSkill) -> Bool {
        selectedKeys.contains(AbilityRosterSkillKey(runtime))
    }

    func failure(for runtime: AbilityRuntimeSkill) -> String? {
        guard !contains(runtime) else { return nil }
        let key = AbilityRosterSkillKey(runtime)
        return trace.decisions.first(where: { $0.key == key })?.reason
            ?? "was not selected by the Ability roster"
    }
}

/// Deterministic, data-only conflict and fallback arbitration.
enum AbilityRosterArbitrator {
    private struct AbilityKey: Hashable, Comparable {
        var packageID: PackageID
        var abilityID: AbilityID

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.packageID.rawValue != rhs.packageID.rawValue {
                return lhs.packageID.rawValue < rhs.packageID.rawValue
            }
            return lhs.abilityID.rawValue < rhs.abilityID.rawValue
        }
    }

    private struct ConflictKey: Hashable, Comparable {
        var packageID: PackageID
        var abilityID: AbilityID
        var group: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.packageID.rawValue != rhs.packageID.rawValue {
                return lhs.packageID.rawValue < rhs.packageID.rawValue
            }
            if lhs.abilityID.rawValue != rhs.abilityID.rawValue {
                return lhs.abilityID.rawValue < rhs.abilityID.rawValue
            }
            return lhs.group < rhs.group
        }
    }

    private struct Candidate {
        var runtime: AbilityRuntimeSkill
        var score: AbilityRoutingEvidenceScore
        var fallbackFor: AbilitySkillReference?

        var key: AbilityRosterSkillKey { AbilityRosterSkillKey(runtime) }
    }

    /// `baseFailure` is Mary's complete pre-arbitration safety gate. The
    /// arbitrator can only remove candidates from that safe set; it can never
    /// create adapter availability, permission, confirmation, Interaction
    /// authority, or workflow safety that the runtime did not already prove.
    static func arbitrate(
        skills: [AbilityRuntimeSkill],
        context: AbilityRoutingContext,
        baseFailure: (AbilityRuntimeSkill) -> String?
    ) -> AbilityRosterArbitration {
        let ordered = skills.sorted(by: stableOrder)
        let byAbility = Dictionary(grouping: ordered) {
            AbilityKey(packageID: $0.packageID, abilityID: $0.ability.id)
        }
        let failures = Dictionary(
            uniqueKeysWithValues: ordered.compactMap { runtime in
                baseFailure(runtime).map { (AbilityRosterSkillKey(runtime), $0) }
            })
        var decisions: [AbilityRosterSkillKey: AbilityRosterDecision] = [:]

        for runtime in ordered {
            let key = AbilityRosterSkillKey(runtime)
            let score = evidence(
                policy: runtime.skill.routing,
                requirements: runtime.skill.requirements,
                context: context)
            if let failure = failures[key] {
                decisions[key] = decision(
                    runtime,
                    disposition: .ineligible,
                    score: score,
                    reason: failure)
            }
        }

        // Ability-level conflict groups operate across packages. This is the
        // intentional seam for choosing Writing vs Coding vs another imported
        // Ability — PEER DISCIPLINES, when a turn is ambiguous about which
        // craft it is. An explicitly selected Ability may retain a routed
        // support Ability, but support never bypasses that Ability's own base
        // policy.
        //
        // AN APPLICATION ABILITY EXTENDS A DISCIPLINE; IT DOES NOT CONTEST IT.
        //
        // THE FAILURE THIS FIXES, measured live in a taught Scrivener: both
        // `writing.mary` and `scrivener.mary` declared
        // `conflictGroup: "ability"`, so they entered the same winner-take-all
        // election — and the arithmetic made it unwinnable for both at once.
        // Writing's `.intent` predicate scores 100, Scrivener's
        // `.namedApplication` scores 70, so on a compose turn Writing won and
        // ALL EIGHT of Scrivener's own verbs were dropped as `.inactiveAbility`;
        // on any other turn Writing's predicate failed, Scrivener won, and the
        // support closure below refused to re-admit Writing because it needs a
        // base-eligible Skill — so `type_at_cursor` came back "was not offered
        // in this turn's Skill roster — it does not match its Ability-level
        // routing policy". Exactly one half of the manuscript vocabulary was
        // reachable per turn, always.
        //
        // The package said "I extend Writing" three times — `paradigm:
        // applicationExpertise`, a non-optional dependency on `writing`, and
        // `defaultSupportingAbilities: ["writing"]` — and "I compete with
        // Writing" once, and the one won. `AbilityParadigm`'s own header is
        // unambiguous: "The two compose; they are not alternatives", and "An
        // application Ability extends a discipline rather than replacing it."
        //
        // So an `applicationExpertise` Ability is admitted on its OWN base
        // eligibility (the `members.contains` guard below, unchanged) and
        // brings its declared supporting Abilities. It never displaces a
        // discipline and can never be displaced by one. Note this is not a
        // Scrivener repair: `design`/`sketch` and `browsing`/`chrome` compose
        // today only because their predicate vocabularies happen to SCORE
        // IDENTICALLY (70 vs 70) and fall through the tie clause — an accident
        // that the next package to gate on `.intent` would have broken too.
        var activeAbilities = Set<AbilityKey>()
        var groupedAbilities: [String: [AbilityKey]] = [:]
        for abilityKey in byAbility.keys.sorted() {
            let members = byAbility[abilityKey] ?? []
            guard members.contains(where: { failures[AbilityRosterSkillKey($0)] == nil }),
                  let ability = members.first?.ability
            else { continue }
            if ability.paradigm == .applicationExpertise {
                activeAbilities.insert(abilityKey)
            } else if let group = normalizedGroup(ability.routing.conflictGroup) {
                groupedAbilities[group, default: []].append(abilityKey)
            } else {
                activeAbilities.insert(abilityKey)
            }
        }
        for group in groupedAbilities.keys.sorted() {
            let keys = groupedAbilities[group, default: []].sorted()
            let candidates = keys.compactMap { key -> (AbilityKey, AbilitySchema, AbilityRoutingEvidenceScore)? in
                guard let ability = byAbility[key]?.first?.ability else { return nil }
                return (
                    key,
                    ability,
                    evidence(policy: ability.routing, requirements: nil, context: context))
            }
            let policies = candidates.map { $0.1.routing.conflictPolicy }
            switch resolvedPolicy(policies, scores: candidates.map(\.2)) {
            case .askUser where candidates.count > 1,
                 .abstain where candidates.count > 1:
                break
            case let policy:
                let ranked = candidates.sorted(by: {
                    ranksBefore(
                        ($0.2, $0.0.abilityID.rawValue),
                        ($1.2, $1.0.abilityID.rawValue),
                        policy: policy)
                })
                if let best = ranked.first {
                    let bestRank = rankVector(best.2, policy: policy)
                    for winner in ranked where rankVector(
                        winner.2,
                        policy: policy) == bestRank {
                        activeAbilities.insert(winner.0)
                    }
                }
            }
        }

        // Supporting Abilities are additions to a winning route, not escapes
        // from it. Only a support package with at least one base-eligible Skill
        // can enter the closure.
        var changed = true
        while changed {
            changed = false
            for key in activeAbilities.sorted() {
                guard let ability = byAbility[key]?.first?.ability else { continue }
                let wanted = Set(
                    ability.operatingPolicy.defaultSupportingAbilities
                        + (byAbility[key] ?? []).flatMap {
                            $0.skill.requirements.supportingAbilities
                        })
                for support in wanted.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let matches = byAbility.keys.filter { $0.abilityID == support }.sorted()
                    for match in matches where (byAbility[match] ?? []).contains(where: {
                        failures[AbilityRosterSkillKey($0)] == nil
                    }) {
                        if activeAbilities.insert(match).inserted { changed = true }
                    }
                }
            }
        }

        for (abilityKey, members) in byAbility where !activeAbilities.contains(abilityKey) {
            for runtime in members {
                let key = AbilityRosterSkillKey(runtime)
                guard failures[key] == nil else { continue }
                decisions[key] = decision(
                    runtime,
                    disposition: .inactiveAbility,
                    score: evidence(
                        policy: runtime.skill.routing,
                        requirements: runtime.skill.requirements,
                        context: context),
                    reason: "its Ability lost or conservatively declined the active Ability conflict")
            }
        }

        let abilityEligible = ordered.filter {
            activeAbilities.contains(AbilityKey(
                packageID: $0.packageID,
                abilityID: $0.ability.id))
                && failures[AbilityRosterSkillKey($0)] == nil
        }

        // A Skill named as a fallback is standby-only. It becomes a candidate
        // exactly when an unavailable primary in the same package and Ability
        // reaches it in declaration order. If any available primary owns that
        // fallback, it remains hidden so the provider never receives both.
        let allFallbackTargets = Set(ordered.flatMap { owner in
            owner.skill.routing.fallbacks.compactMap { fallbackID in
                ordered.first(where: {
                    $0.packageID == owner.packageID
                        && $0.ability.id == owner.ability.id
                        && $0.skill.id == fallbackID
                }).map(AbilityRosterSkillKey.init)
            }
        })
        var activeCandidates: [AbilityRosterSkillKey: Candidate] = [:]
        for runtime in abilityEligible where !allFallbackTargets.contains(AbilityRosterSkillKey(runtime)) {
            let key = AbilityRosterSkillKey(runtime)
            activeCandidates[key] = Candidate(
                runtime: runtime,
                score: evidence(
                    policy: runtime.skill.routing,
                    requirements: runtime.skill.requirements,
                    context: context),
                fallbackFor: nil)
        }

        let availableOwnersByFallback = Dictionary(grouping: abilityEligible.flatMap { owner in
            owner.skill.routing.fallbacks.compactMap { fallbackID in
                ordered.first(where: {
                    $0.packageID == owner.packageID
                        && $0.ability.id == owner.ability.id
                        && $0.skill.id == fallbackID
                }).map { (AbilityRosterSkillKey($0), owner) }
            }
        }, by: { $0.0 })

        func fallbackCandidate(
            for primary: AbilityRuntimeSkill,
            visited: Set<AbilityRosterSkillKey>
        ) -> AbilityRuntimeSkill? {
            for fallbackID in primary.skill.routing.fallbacks {
                guard let candidate = ordered.first(where: {
                    $0.packageID == primary.packageID
                        && $0.ability.id == primary.ability.id
                        && $0.skill.id == fallbackID
                }) else { continue }
                let key = AbilityRosterSkillKey(candidate)
                guard !visited.contains(key) else { continue }
                if failures[key] == nil,
                   activeAbilities.contains(AbilityKey(
                       packageID: candidate.packageID,
                       abilityID: candidate.ability.id)) {
                    let liveOwners = availableOwnersByFallback[key, default: []]
                        .map(\.1)
                        .filter { AbilityRosterSkillKey($0) != AbilityRosterSkillKey(primary) }
                    if liveOwners.isEmpty { return candidate }
                }
                var next = visited
                next.insert(key)
                if let nested = fallbackCandidate(for: candidate, visited: next) {
                    return nested
                }
            }
            return nil
        }

        for primary in ordered where failures[AbilityRosterSkillKey(primary)] != nil {
            let abilityKey = AbilityKey(
                packageID: primary.packageID,
                abilityID: primary.ability.id)
            guard activeAbilities.contains(abilityKey),
                  let fallback = fallbackCandidate(
                      for: primary,
                      visited: [AbilityRosterSkillKey(primary)])
            else { continue }
            let fallbackKey = AbilityRosterSkillKey(fallback)
            if activeCandidates[fallbackKey] == nil {
                activeCandidates[fallbackKey] = Candidate(
                    runtime: fallback,
                    score: evidence(
                        policy: fallback.skill.routing,
                        requirements: fallback.skill.requirements,
                        context: context),
                    fallbackFor: primary.reference)
            }
        }

        for runtime in abilityEligible where allFallbackTargets.contains(AbilityRosterSkillKey(runtime)) {
            let key = AbilityRosterSkillKey(runtime)
            guard activeCandidates[key] == nil else { continue }
            let owner = availableOwnersByFallback[key, default: []]
                .map(\.1)
                .sorted(by: stableOrder)
                .first
            decisions[key] = decision(
                runtime,
                disposition: .fallbackStandby,
                score: evidence(
                    policy: runtime.skill.routing,
                    requirements: runtime.skill.requirements,
                    context: context),
                selectedAlternative: owner?.reference,
                reason: owner == nil
                    ? "is a standby fallback and no unavailable primary activated it"
                    : "is a standby fallback while its primary is eligible")
        }

        // Skill conflict groups are deliberately package/Ability scoped. An
        // imported package cannot suppress a separate package merely by
        // guessing its group string. Cross-Ability selection belongs to the
        // Ability-level group handled above.
        var selected = Set<AbilityRosterSkillKey>()
        let candidates = activeCandidates.values.sorted { stableOrder($0.runtime, $1.runtime) }
        let grouped = Dictionary(grouping: candidates) { candidate -> ConflictKey? in
            normalizedGroup(candidate.runtime.skill.routing.conflictGroup).map {
                ConflictKey(
                    packageID: candidate.runtime.packageID,
                    abilityID: candidate.runtime.ability.id,
                    group: $0)
            }
        }
        for candidate in grouped[nil, default: []] {
            selected.insert(candidate.key)
            decisions[candidate.key] = decision(
                candidate.runtime,
                disposition: .selected,
                score: candidate.score,
                fallbackFor: candidate.fallbackFor,
                reason: candidate.fallbackFor == nil
                    ? "selected with no conflict group"
                    : "selected as the first safe fallback for an unavailable primary")
        }
        let conflictKeys = grouped.keys.compactMap { $0 }.sorted()
        for conflictKey in conflictKeys {
            let group = grouped[conflictKey, default: []]
            guard !group.isEmpty else { continue }
            if group.count == 1, let only = group.first {
                selected.insert(only.key)
                decisions[only.key] = decision(
                    only.runtime,
                    disposition: .selected,
                    score: only.score,
                    fallbackFor: only.fallbackFor,
                    reason: only.fallbackFor == nil
                        ? "selected as the only eligible member of \(conflictKey.group)"
                        : "selected as the only safe fallback in \(conflictKey.group)")
                continue
            }
            let policy = resolvedPolicy(
                group.map { $0.runtime.skill.routing.conflictPolicy },
                scores: group.map(\.score))
            switch policy {
            case .askUser:
                for candidate in group {
                    decisions[candidate.key] = decision(
                        candidate.runtime,
                        disposition: .clarificationRequired,
                        score: candidate.score,
                        fallbackFor: candidate.fallbackFor,
                        reason: "conflict group \(conflictKey.group) requires user clarification")
                }
            case .abstain:
                for candidate in group {
                    decisions[candidate.key] = decision(
                        candidate.runtime,
                        disposition: .abstained,
                        score: candidate.score,
                        fallbackFor: candidate.fallbackFor,
                        reason: "conflict group \(conflictKey.group) conservatively abstained")
                }
            case .highestEvidence, .preferDirectInteraction, .preferFocusedWorkspace:
                let ranked = group.sorted {
                    ranksBefore(
                        ($0.score, $0.runtime.skill.id.rawValue),
                        ($1.score, $1.runtime.skill.id.rawValue),
                        policy: policy)
                }
                guard let firstWinner = ranked.first else { continue }
                let bestRank = rankVector(firstWinner.score, policy: policy)
                let winners = ranked.filter {
                    rankVector($0.score, policy: policy) == bestRank
                }
                let winnerKeys = Set(winners.map(\.key))
                for winner in winners {
                    selected.insert(winner.key)
                    decisions[winner.key] = decision(
                        winner.runtime,
                        disposition: .selected,
                        score: winner.score,
                        fallbackFor: winner.fallbackFor,
                        reason: "selected in the maximal typed-evidence set by \(policy.rawValue) in \(conflictKey.group)")
                }
                for loser in ranked where !winnerKeys.contains(loser.key) {
                    decisions[loser.key] = decision(
                        loser.runtime,
                        disposition: .conflictLost,
                        score: loser.score,
                        selectedAlternative: firstWinner.runtime.reference,
                        fallbackFor: loser.fallbackFor,
                        reason: "\(firstWinner.runtime.reference.displayLabel) had stronger typed evidence in \(conflictKey.group) by \(policy.rawValue)")
                }
            }
        }

        // Every activated package Skill receives a decision, including malformed
        // fallback cycles that deliberately activate nothing.
        for runtime in ordered where decisions[AbilityRosterSkillKey(runtime)] == nil {
            let key = AbilityRosterSkillKey(runtime)
            decisions[key] = decision(
                runtime,
                disposition: .fallbackStandby,
                score: evidence(
                    policy: runtime.skill.routing,
                    requirements: runtime.skill.requirements,
                    context: context),
                reason: "remained standby after bounded fallback resolution")
        }

        let trace = AbilityRosterTrace(decisions: decisions.values.sorted {
            stableOrder($0.reference, $1.reference)
        })
        return AbilityRosterArbitration(selectedKeys: selected, trace: trace)
    }

}
