//
//  AbilityRosterArbitrator.swift
//  MaryBrain
//
//  WHAT: Closed roster stage — which Skills are callable this turn.
//  IN:   AbilityRuntime.Snapshot + route + safety gate
//  OUT:  AbilityRosterArbitration (selectedKeys + trace)
//  PIN:  selectedKeys is the single authority for schema, counts, and dispatch.
//
import MaryFoundation
import Foundation

/// Stable identity for one Skill in an activated package.
struct AbilityRosterArbitration: Sendable {
    var selectedKeys: Set<AbilityRosterSkillKey>
    var trace: AbilityRosterTrace
    /// The trace's own reasons, keyed. `failure(for:)` is asked once per skill
    /// by the offer ledger and again per circuit skill by the turn log, and a
    /// linear scan of every decision per ask is the same answer more slowly.
    var reasons: [AbilityRosterSkillKey: String] = [:]

    func contains(_ runtime: AbilityRuntimeSkill) -> Bool {
        selectedKeys.contains(AbilityRosterSkillKey(runtime))
    }

    func failure(for runtime: AbilityRuntimeSkill) -> String? {
        guard !contains(runtime) else { return nil }
        return reasons[AbilityRosterSkillKey(runtime)]
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

    /// `baseFailure` is Mary's complete pre-arbitration safety gate.
    static func arbitrate(
        skills: [AbilityRuntimeSkill],
        context: AbilityRoutingContext,
        baseFailure: (AbilityRuntimeSkill) -> String?
    ) -> AbilityRosterArbitration {
        // SORT THE INDICES, NOT THE SKILLS. `stableOrder` is three string
        // compares, but `sorted` MOVES its elements, and an AbilityRuntimeSkill
        // carries a whole authored ability, skill schema, availability and
        // reference — so every move was a fistful of retains. Ordering ints and
        // materializing once costs a fraction of the same answer.
        let ordered = orderedStably(skills)
        let byAbility = Dictionary(grouping: ordered) {
            AbilityKey(packageID: $0.packageID, abilityID: $0.ability.id)
        }
        // Fallbacks are authored as a Skill id and resolved WITHIN the owner's
        // own package and ability. Keyed once, that resolution is a lookup;
        // scanning `ordered` for each one made the whole pass quadratic.
        let byKey = Dictionary(
            ordered.map { (AbilityRosterSkillKey($0), $0) },
            uniquingKeysWith: { first, _ in first })
        func sibling(
            of owner: AbilityRuntimeSkill, skillID: SkillID
        ) -> AbilityRuntimeSkill? {
            byKey[AbilityRosterSkillKey(
                packageID: owner.packageID,
                abilityID: owner.ability.id,
                skillID: skillID)]
        }
        // ONE EVIDENCE PASS. The score is a pure function of the skill's own
        // routing policy, its requirements and this turn's context — none of
        // which change during arbitration — and it was being recomputed for
        // the same skill in as many as four separate passes below.
        let scores: [AbilityRosterSkillKey: AbilityRoutingEvidenceScore] = Dictionary(
            uniqueKeysWithValues: ordered.map { runtime in
                (AbilityRosterSkillKey(runtime), evidence(
                    policy: runtime.skill.routing,
                    requirements: runtime.skill.requirements,
                    context: context,
                    skillID: runtime.skill.id))
            })
        func score(
            _ runtime: AbilityRuntimeSkill,
            key: AbilityRosterSkillKey? = nil
        ) -> AbilityRoutingEvidenceScore {
            scores[key ?? AbilityRosterSkillKey(runtime)] ?? evidence(
                policy: runtime.skill.routing,
                requirements: runtime.skill.requirements,
                context: context,
                skillID: runtime.skill.id)
        }
        let failures = Dictionary(
            uniqueKeysWithValues: ordered.compactMap { runtime in
                baseFailure(runtime).map { (AbilityRosterSkillKey(runtime), $0) }
            })
        var decisions: [AbilityRosterSkillKey: AbilityRosterDecision] = [:]

        for runtime in ordered {
            let key = AbilityRosterSkillKey(runtime)
            let score = score(runtime, key: key)
            if let failure = failures[key] {
                decisions[key] = decision(
                    runtime,
                    disposition: .ineligible,
                    score: score,
                    reason: failure)
            }
        }

        // Ability-level conflict groups operate across packages.
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
                    score: score(runtime, key: key),
                    reason: "its Ability lost or conservatively declined the active Ability conflict")
            }
        }

        let abilityEligible = ordered.filter {
            activeAbilities.contains(AbilityKey(
                packageID: $0.packageID,
                abilityID: $0.ability.id))
                && failures[AbilityRosterSkillKey($0)] == nil
        }

        // A Skill named as a fallback is standby-only.
        let allFallbackTargets = Set(ordered.flatMap { owner in
            owner.skill.routing.fallbacks.compactMap { fallbackID in
                sibling(of: owner, skillID: fallbackID).map(AbilityRosterSkillKey.init)
            }
        })
        var activeCandidates: [AbilityRosterSkillKey: Candidate] = [:]
        for runtime in abilityEligible where !allFallbackTargets.contains(AbilityRosterSkillKey(runtime)) {
            let key = AbilityRosterSkillKey(runtime)
            activeCandidates[key] = Candidate(
                runtime: runtime,
                score: score(runtime, key: key),
                fallbackFor: nil)
        }

        let availableOwnersByFallback = Dictionary(grouping: abilityEligible.flatMap { owner in
            owner.skill.routing.fallbacks.compactMap { fallbackID in
                sibling(of: owner, skillID: fallbackID)
                    .map { (AbilityRosterSkillKey($0), owner) }
            }
        }, by: { $0.0 })

        func fallbackCandidate(
            for primary: AbilityRuntimeSkill,
            visited: Set<AbilityRosterSkillKey>
        ) -> AbilityRuntimeSkill? {
            for fallbackID in primary.skill.routing.fallbacks {
                guard let candidate = sibling(of: primary, skillID: fallbackID)
                else { continue }
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
                    score: score(fallback, key: fallbackKey),
                    fallbackFor: primary.reference)
            }
        }

        for runtime in abilityEligible where allFallbackTargets.contains(AbilityRosterSkillKey(runtime)) {
            let key = AbilityRosterSkillKey(runtime)
            guard activeCandidates[key] == nil else { continue }
            let owner = availableOwnersByFallback[key, default: []]
                .map(\.1)
                .min(by: stableOrder)
            decisions[key] = decision(
                runtime,
                disposition: .fallbackStandby,
                score: score(runtime, key: key),
                selectedAlternative: owner?.reference,
                reason: owner == nil
                    ? "is a standby fallback and no unavailable primary activated it"
                    : "is a standby fallback while its primary is eligible")
        }

        // Skill conflict groups are deliberately package/Ability scoped. An imported package cannot suppress a separate package merely by guessing its group string.
        var selected = Set<AbilityRosterSkillKey>()
        let candidates = orderedStably(Array(activeCandidates.values), by: \.runtime.reference)
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
                score: score(runtime, key: key),
                reason: "remained standby after bounded fallback resolution")
        }

        let trace = AbilityRosterTrace(
            decisions: orderedStably(Array(decisions.values), by: \.reference))
        return AbilityRosterArbitration(
            selectedKeys: selected,
            trace: trace,
            reasons: decisions.mapValues(\.reason))
    }

}
