//
//  AbilityStudioRoutingRehearsal.swift
//  Mary
//
//  WHAT: Run a sentence through the real routing indexes and say what happens.
//  IN:   Tune pane's rehearsal sheet.
//  OUT:  snapshot.abilityAffinities / semanticSkillIndex.affinities /
//        EmbeddingRouting.uniqueWinner — the same calls the turn loop makes.
//  PIN:  Not a simulation. And the lever it points at is a FIXTURE: an ability's
//        phrases feed the ability tier only, so they can never separate two
//        skills inside one ability.
//

import MaryBrain
import SwiftUI

struct AbilityStudioRehearsal {

    /// Where a candidate sits relative to the two thresholds that decide
    /// whether Mary may skip the model entirely.
    enum Standing: Hashable {
        /// Clears the floor and beats everything else by the margin.
        case winner
        /// Clears the floor and sits inside the winner's margin — this is what
        /// blocks the shortcut.
        case crowding
        /// Clears the floor but is not in contention.
        case contender
        /// Below the floor; the embedding has no opinion worth acting on.
        case belowFloor
    }

    struct Candidate: Identifiable, Hashable {
        let id: String
        let title: String
        let invocation: String?
        let affinity: Float
        let deltaToWinner: Float
        let standing: Standing
        let ownerTitle: String
        let ownerTint: String
        /// Set for skill-tier rows: what the arbitrator would weigh if the
        /// shortcut is blocked and the turn goes to the model.
        let conflictGroup: String?
        let conflictPolicy: RoutingConflictPolicy?
        let preference: Int?
        let readiness: SkillReadiness?

        var color: Color {
            switch standing {
            case .winner: return .maryGreen
            case .crowding: return .maryError
            case .contender: return .maryGold
            case .belowFloor: return Paper.graphite
            }
        }
    }

    /// What the turn loop would do with this sentence.
    enum Verdict: Hashable {
        /// One skill clears the floor and the margin — the turn dispatches with
        /// no model round at all.
        case dispatches(String)
        /// Two or more sit within the margin; the shortcut is suppressed.
        case tooClose(winner: String, crowder: String, delta: Float)
        /// Nothing clears the floor.
        case nothingMatched
        /// No embedding backend, so there is no opinion to have.
        case noBackend
    }

    let utterance: String
    let abilities: [Candidate]
    let skills: [Candidate]
    let verdict: Verdict
    /// The registry these numbers came from. Indexes are built at reload, so a
    /// fixture added now changes them only after Save.
    let revision: String

    static let floor = EmbeddingRouting.floor
    static let margin = EmbeddingRouting.margin

    /// Nil when there is no vectorizer at all — the caller says "no embedding
    /// backend" rather than drawing zeros.
    static func run(
        utterance: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> AbilityStudioRehearsal {
        let revision = String(snapshot.revision.uuidString.prefix(8))
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MaryEmbeddings.vectorizer() != nil, !trimmed.isEmpty else {
            return AbilityStudioRehearsal(
                utterance: trimmed,
                abilities: [],
                skills: [],
                verdict: trimmed.isEmpty ? .nothingMatched : .noBackend,
                revision: revision)
        }

        let skillAffinities = snapshot.semanticSkillIndex?
            .affinities(in: trimmed, exemplars: .shared) ?? [:]
        let abilityAffinities = snapshot.abilityAffinities(in: trimmed)

        let skills = rankedSkills(skillAffinities, snapshot: snapshot)
        let abilities = rankedAbilities(abilityAffinities, snapshot: snapshot)

        return AbilityStudioRehearsal(
            utterance: trimmed,
            abilities: abilities,
            skills: skills,
            verdict: verdict(for: skills, affinities: skillAffinities, snapshot: snapshot),
            revision: revision)
    }

    // MARK: - Ranking

    private static func rankedSkills(
        _ affinities: [SkillID: Float],
        snapshot: AbilityRuntimeSnapshot
    ) -> [Candidate] {
        let ranked = affinities.sorted { $0.value > $1.value }
        let best = ranked.first?.value ?? 0
        return ranked.map { skillID, affinity in
            let runtime = snapshot.skill(id: skillID)
            let delta = best - affinity
            return Candidate(
                id: skillID.rawValue,
                title: runtime?.skill.title ?? skillID.rawValue,
                invocation: runtime?.skill.modelExposure.invocationName,
                affinity: affinity,
                deltaToWinner: delta,
                standing: standing(affinity: affinity, delta: delta, isBest: affinity == best),
                ownerTitle: runtime?.ability.title ?? "unknown",
                ownerTint: runtime?.ability.tint ?? "",
                conflictGroup: runtime?.skill.routing.conflictGroup
                    ?? runtime?.ability.routing.conflictGroup,
                conflictPolicy: runtime?.skill.routing.conflictPolicy,
                preference: runtime?.skill.routing.preference,
                readiness: runtime?.availability.readiness)
        }
    }

    private static func rankedAbilities(
        _ affinities: [AbilityID: Float],
        snapshot: AbilityRuntimeSnapshot
    ) -> [Candidate] {
        let ranked = affinities.sorted { $0.value > $1.value }
        let best = ranked.first?.value ?? 0
        return ranked.map { abilityID, affinity in
            let record = snapshot.records.first { $0.package.ability.id == abilityID }
            let delta = best - affinity
            return Candidate(
                id: abilityID.rawValue,
                title: record?.package.ability.title ?? abilityID.rawValue,
                invocation: nil,
                affinity: affinity,
                deltaToWinner: delta,
                standing: standing(affinity: affinity, delta: delta, isBest: affinity == best),
                ownerTitle: record?.package.ability.title ?? abilityID.rawValue,
                ownerTint: record?.package.ability.tint ?? "",
                conflictGroup: record?.package.ability.routing.conflictGroup,
                conflictPolicy: record?.package.ability.routing.conflictPolicy,
                preference: record?.package.ability.routing.preference,
                readiness: nil)
        }
    }

    private static func standing(
        affinity: Float,
        delta: Float,
        isBest: Bool
    ) -> Standing {
        guard affinity >= floor else { return .belowFloor }
        if isBest { return .winner }
        return delta < margin ? .crowding : .contender
    }

    /// Mirrors `EmbeddingRouting.uniqueWinner`: a shortcut needs the floor AND
    /// the margin, and the winner must be ready and model-exposed.
    private static func verdict(
        for skills: [Candidate],
        affinities: [SkillID: Float],
        snapshot: AbilityRuntimeSnapshot
    ) -> Verdict {
        let above = skills.filter { $0.standing != .belowFloor }
        guard let leader = above.first else { return .nothingMatched }
        if let winner = EmbeddingRouting.uniqueWinner(
            affinities: affinities,
            snapshot: snapshot) {
            return .dispatches(winner.skill.title)
        }
        if let crowder = above.dropFirst().first, crowder.standing == .crowding {
            return .tooClose(
                winner: leader.title,
                crowder: crowder.title,
                delta: crowder.deltaToWinner)
        }
        // Cleared the floor and the margin, but the winner is not ready or not
        // model-exposed — `uniqueWinner` refuses those too.
        return .tooClose(winner: leader.title, crowder: leader.title, delta: 0)
    }

    // MARK: - Reading

    var verdictWord: String {
        switch verdict {
        case .dispatches(let title):
            return "Mary answers with \(title), no model round at all."
        case .tooClose(let winner, let crowder, let delta) where winner != crowder:
            return "\(crowder) sits \(String(format: "%.2f", delta)) under \(winner), inside the \(String(format: "%.2f", Self.margin)) margin — Mary will not take the shortcut."
        case .tooClose(let winner, _, _):
            return "\(winner) leads, but is not ready to be dispatched — the turn goes to the model."
        case .nothingMatched:
            return "Nothing clears the floor. The model decides this turn."
        case .noBackend:
            return "No embedding backend on this machine, so there is no opinion to have."
        }
    }

    var isClean: Bool {
        if case .dispatches = verdict { return true }
        return false
    }

    /// The crowder, when there is one — the row a fixture is meant to separate.
    var crowder: Candidate? {
        skills.dropFirst().first { $0.standing == .crowding }
    }
}
