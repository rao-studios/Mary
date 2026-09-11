//
//  ApplicationReferenceResolution.swift
//  MaryBrain
//
//  WHAT: Which application a system-control Skill was pointed at, ranked.
//  IN:   the winning Skill + the utterance + the turn's asserted applications
//  OUT:  the application argument at dispatch; the rehearsal's candidate tier
//  PIN:  ONE RESOLVER, NOT TWO — the turn loop, the Sand bench and Ability
//        Studio's rehearsal all call this, for the same reason
//        `ExpertiseResolution` says so: a rehearsal that reimplemented the
//        ranking would be a simulation, and would drift the first time either
//        side was tuned.
//  PIN:  WORDS BEAT DISTANCE, ALWAYS. Naming an application is an instruction;
//        embedding distance is what answers when nothing was named outright.
//  PIN:  NO HABIT TIER HERE. `ApplicationHabitLedger` is keyed by DISCIPLINE —
//        "which player do they use for music" — and a system-control ability is
//        not one. "Open a new window" has no habitual application: the answer
//        is whichever one they just said, or none.
//
import Foundation
import MaryFoundation

public enum ApplicationReferenceResolution {

    /// Why a candidate is where it is.
    public enum Standing: String, Sendable, Hashable {
        /// The sentence used one of this application's own declared names.
        case named
        /// Nothing was named; this leads the distance ranking by the margin.
        case nearest
        /// Scored, but did not lead — or led without clearing the margin.
        case considered
        /// In the candidate set, but the words reached it not at all.
        case unreached
    }

    public struct Candidate: Sendable, Hashable, Identifiable {
        public var abilityID: AbilityID
        public var applicationID: String
        public var title: String
        /// Cosine similarity, or nil when this candidate was never scored —
        /// no index, or the words did not reach it. Nil and 0.0 are different
        /// facts and the benches draw them differently.
        public var score: Float?
        public var standing: Standing

        public var id: AbilityID { abilityID }
    }

    /// What the reverse lookup found.
    public struct Verdict: Sendable, Hashable {
        /// The system-control Ability that owns the Skill being resolved.
        public var hostID: AbilityID
        /// Ranked: named first, then by score, then by id.
        public var candidates: [Candidate]
        /// The one to act on, or nil — nothing named and nothing near enough.
        /// NIL IS AN ANSWER. It falls to the model, which can ask which app
        /// they meant; naming the wrong editor cannot be taken back.
        public var chosen: Candidate?

        /// True when the words named it rather than merely leaning toward it.
        public var wasNamed: Bool { chosen?.standing == .named }
    }

    /// Nil when the Skill did not declare `resolvesApplication`, or when its
    /// Ability has no application-bearing dependents — there is no question to
    /// answer and no tier to draw.
    ///
    /// `assertedApplicationIDs` is what the turn already established the person
    /// named (`ApplicationProfile.isMentioned`, run once per turn on the whole
    /// roster). Exactly one of them inside the candidate set wins outright.
    public static func resolve(
        for skill: AbilityRuntimeSkill,
        snapshot: AbilityRuntime.Snapshot,
        utterance: String,
        assertedApplicationIDs: Set<String> = []
    ) -> Verdict? {
        let host = skill.ability.id
        let candidateIDs = snapshot.applicationCandidates(for: skill)
        guard !candidateIDs.isEmpty else { return nil }

        // The host's own vocabulary — the words that name the ABILITY, not any
        // one application. "Window" is window-management's; it must not name a
        // browser just because browsers talk about windows.
        let hostVocabulary = vocabulary(of: host, snapshot: snapshot)

        let ranked = snapshot.semanticApplicationIndex?.ranked(
            in: utterance, candidates: candidateIDs, excluding: hostVocabulary) ?? []
        let scores = Dictionary(
            ranked.map { ($0.abilityID, $0.score) },
            uniquingKeysWith: { first, _ in first })

        var candidates: [Candidate] = candidateIDs.compactMap { abilityID in
            guard let applicationID = snapshot.applicationID(ofAbility: abilityID)
            else { return nil }
            let record = snapshot.records.first { $0.package.ability.id == abilityID }
            let score = scores[abilityID]
            return Candidate(
                abilityID: abilityID,
                applicationID: applicationID,
                title: record?.package.ability.title ?? abilityID.rawValue,
                score: score,
                standing: score == nil ? .unreached : .considered)
        }
        guard !candidates.isEmpty else { return nil }

        // Ranking: scored before unscored, then by score, then by id — stable
        // across launches, the same rule the reverse index sorts by.
        candidates.sort {
            switch ($0.score, $1.score) {
            case let (lhs?, rhs?): return lhs != rhs
                ? lhs > rhs
                : $0.abilityID.rawValue < $1.abilityID.rawValue
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.abilityID.rawValue < $1.abilityID.rawValue
            }
        }

        // TIER 1 — THE WORDS. Exactly one candidate named outright wins, and
        // no distance can overturn it. Two named is a genuine ambiguity in the
        // sentence, and picking one of them would be inventing an answer.
        let asserted = Set(assertedApplicationIDs.map { $0.lowercased() })
        let named = candidates.indices.filter {
            asserted.contains(candidates[$0].applicationID.lowercased())
        }
        if named.count == 1 {
            var chosen = candidates.remove(at: named[0])
            chosen.standing = .named
            candidates.insert(chosen, at: 0)
            return Verdict(hostID: host, candidates: candidates, chosen: chosen)
        }

        // TIER 2 — THE DISTANCE. The floor and margin belong to the index and
        // are applied by it, so the bench and the turn cannot drift apart about
        // what counts as near enough. `leader(of:)` takes the ranking computed
        // above rather than rescoring — this is the turn path.
        guard named.isEmpty,
              let match = snapshot.semanticApplicationIndex?.leader(of: ranked),
              let position = candidates.firstIndex(where: {
                  $0.abilityID == match.abilityID
              })
        else {
            return Verdict(hostID: host, candidates: candidates, chosen: nil)
        }
        candidates[position].standing = .nearest
        return Verdict(
            hostID: host, candidates: candidates, chosen: candidates[position])
    }

    /// Every word the HOST ability answers to — its own aliases and trigger
    /// vocabulary. Directly parallel to `ExpertiseResolution`'s
    /// `disciplineVocabulary`, for the identical reason.
    static func vocabulary(
        of host: AbilityID, snapshot: AbilityRuntime.Snapshot
    ) -> Set<String> {
        guard let package = snapshot.records.first(where: {
            $0.package.ability.id == host
        })?.package else { return [] }
        return Set(
            (package.ability.aliases
                + package.ability.triggers.tokens
                + package.ability.triggers.phrases)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty })
    }
}
