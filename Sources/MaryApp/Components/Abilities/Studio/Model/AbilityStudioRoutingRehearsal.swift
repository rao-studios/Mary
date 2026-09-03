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
        /// One skill clears the floor and the margin AND has a shape the
        /// shortcut can fill — the turn dispatches with no model round at all.
        case dispatches(String, in: String?)
        /// Wins its tier, but its arguments are not a spoken span the shortcut
        /// may fill (an enum, a composed value), so the turn takes one model
        /// round with this Skill offered first. `confidenceShape` is the gate.
        case modelFills(leader: String, in: String?)
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
    /// Who inherits the winning Skill's discipline, ranked by habit. Nil when
    /// the winner's ability is not a discipline or nothing extends it.
    let expertise: ExpertiseResolution.Verdict?
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
        snapshot: AbilityRuntime.Snapshot
    ) -> AbilityStudioRehearsal {
        let revision = String(snapshot.revision.uuidString.prefix(8))
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MaryEmbeddings.vectorizer() != nil, !trimmed.isEmpty else {
            return AbilityStudioRehearsal(
                utterance: trimmed,
                abilities: [],
                skills: [],
                expertise: nil,
                verdict: trimmed.isEmpty ? .nothingMatched : .noBackend,
                revision: revision)
        }

        let skillAffinities = snapshot.semanticSkillIndex?
            .affinities(in: trimmed, habits: .shared) ?? [:]
        let abilityAffinities = snapshot.abilityAffinities(in: trimmed)

        let skills = rankedSkills(skillAffinities, snapshot: snapshot)
        let abilities = rankedAbilities(abilityAffinities, snapshot: snapshot)

        // THE THIRD TIER, resolved by the SAME function the dispatch uses. It
        // is asked about the leading Skill whether or not the shortcut fires,
        // because the model lane fills `app` from this ranking too.
        let leader = EmbeddingRouting.uniqueWinner(
            affinities: skillAffinities, snapshot: snapshot)
            ?? skills.first { $0.standing != .belowFloor }
                .flatMap { snapshot.skill(id: SkillID($0.id)) }
        let expertise = leader.flatMap { runtime in
            ExpertiseResolution.resolve(
                for: runtime,
                snapshot: snapshot,
                assertedApplicationIDs: Self.namedApplications(
                    in: trimmed, snapshot: snapshot),
                utterance: trimmed)
        }

        return AbilityStudioRehearsal(
            utterance: trimmed,
            abilities: abilities,
            skills: skills,
            expertise: expertise,
            verdict: verdict(
                for: skills, utterance: trimmed, affinities: skillAffinities,
                snapshot: snapshot, expertise: expertise),
            revision: revision)
    }

    /// Applications this sentence NAMES, by the same test the turn's own gate
    /// uses (`AmbientIntentGate.resolve` → `ApplicationProfile.isMentioned`).
    private static func namedApplications(
        in utterance: String, snapshot: AbilityRuntime.Snapshot
    ) -> Set<String> {
        Set(snapshot.plugins.applicationProfiles
            .filter { $0.isMentioned(in: utterance) }
            .map(\.id))
    }

    // MARK: - Ranking

    private static func rankedSkills(
        _ affinities: [SkillID: Float],
        snapshot: AbilityRuntime.Snapshot
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
        snapshot: AbilityRuntime.Snapshot
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

    /// Mirrors the turn loop's WHOLE gate, not just the tier: a shortcut needs
    /// the floor and the margin (`uniqueWinner`), a ready, model-exposed
    /// winner, AND arguments the shortcut may fill (`confidenceShape`) — plus,
    /// for a verb carrying no span, a single clause.
    ///
    /// THE SHAPE GATE IS NOT DECORATION. `control_playback`'s one required
    /// argument is an enum, so "pause the music" has always taken a model
    /// round; a rehearsal that stopped at `uniqueWinner` promised a shortcut
    /// the turn loop would never take.
    private static func verdict(
        for skills: [Candidate],
        utterance: String,
        affinities: [SkillID: Float],
        snapshot: AbilityRuntime.Snapshot,
        expertise: ExpertiseResolution.Verdict?
    ) -> Verdict {
        let landing = expertise?.chosen?.title
        let above = skills.filter { $0.standing != .belowFloor }
        guard let leader = above.first else { return .nothingMatched }
        if let winner = EmbeddingRouting.uniqueWinner(
            affinities: affinities,
            snapshot: snapshot) {
            guard let shape = EmbeddingRouting.confidenceShape(of: winner) else {
                return .modelFills(leader: winner.skill.title, in: landing)
            }
            if shape == .noRequiredArguments,
               !EmbeddingRouting.isSingleClause(utterance) {
                return .modelFills(leader: winner.skill.title, in: landing)
            }
            return .dispatches(winner.skill.title, in: landing)
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
        case .dispatches(let title, let landing):
            guard let landing else {
                return "Mary answers with \(title), no model round at all."
            }
            return "Mary answers with \(title) in \(landing), no model round at all."
        case .modelFills(let leader, let landing):
            let place = landing.map { " in \($0)" } ?? ""
            return "\(leader) leads, but its arguments are structured, so the model fills them in — one model round, \(leader)\(place) offered first."
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
        switch verdict {
        // A model round that reaches the right Skill in the right application
        // is a correct routing outcome, not a fault — the banner must not
        // shout about a Skill whose arguments simply are not a spoken span.
        case .dispatches, .modelFills: return true
        default: return false
        }
    }

    /// The third tier's one-line reading.
    var expertiseWord: String? {
        guard let expertise, let chosen = expertise.chosen else { return nil }
        switch chosen.standing {
        case .asserted:
            return "\(chosen.title) — you named it."
        case .habitual:
            let runnerUp = expertise.candidates.dropFirst().first?.weight ?? 0
            let seen = chosen.lastSeen.map {
                " — last used \(Self.ago(from: $0))"
            } ?? ""
            return String(
                format: "%@ leads by habit, %.2f vs %.2f%@",
                chosen.title, chosen.weight, runnerUp, seen)
        case .fallback, .staticPreference:
            return "\(chosen.title) — no habit yet, so the packages' own preference decides."
        }
    }

    private static func ago(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// The crowder, when there is one — the row a fixture is meant to separate.
    var crowder: Candidate? {
        skills.dropFirst().first { $0.standing == .crowding }
    }
}
