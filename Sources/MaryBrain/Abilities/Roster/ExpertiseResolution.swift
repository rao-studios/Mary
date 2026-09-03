//
//  ExpertiseResolution.swift
//  MaryBrain
//
//  WHAT: Which player answers a multimedia Skill — the reverse lookup, ranked.
//  IN:   the winning Skill + the turn's asserted applications + the habit ledger
//  OUT:  an `app` argument at dispatch; the rehearsal's expertise tier
//  PIN:  ONE RESOLVER, NOT TWO. The turn loop, the provider ladder and Ability
//        Studio's rehearsal all call this — a rehearsal that reimplemented the
//        ranking would be a simulation, and would drift the first time either
//        side was tuned.
//        WORDS BEAT HABIT, ALWAYS. Naming an app is an instruction; a habit is
//        only what fills the silence when nothing was named.
//
import Foundation
import MaryFoundation
import MaryPlugin

public enum ExpertiseResolution {

    /// Why a candidate is where it is.
    public enum Standing: String, Sendable, Hashable {
        /// The turn's own words (or its frozen provider choice) named it.
        case asserted
        /// Leads the decayed habit ranking.
        case habitual
        /// Has history, but not the most.
        case fallback
        /// No history to go on; the packages' own declared preference decided.
        case staticPreference
    }

    public struct Candidate: Sendable, Hashable, Identifiable {
        public var expertiseID: AbilityID
        public var applicationID: String
        public var title: String
        public var tint: String
        /// Summed recency weight. Zero means "never seen", not "disliked".
        public var weight: Double
        /// This candidate's share of the discipline's whole weight, 0…1.
        public var share: Double
        public var lastSeen: Date?
        /// The package's own declared standing, the cold-start tiebreak.
        public var preference: Int
        public var standing: Standing

        public var id: AbilityID { expertiseID }
    }

    /// What the reverse lookup found for one discipline.
    public struct Verdict: Sendable, Hashable {
        public var disciplineID: AbilityID
        /// Ranked: asserted first, then weight, then declared preference.
        public var candidates: [Candidate]
        /// The one Mary would act in. Non-nil whenever `candidates` is — with
        /// no history at all the declared preference still decides, so a fresh
        /// install acts rather than asking which player the person meant.
        public var chosen: Candidate?

        /// True when the pick is the person's own habit rather than a default.
        public var isHabitual: Bool { chosen?.standing == .habitual }
    }

    /// Nil when the Skill's owner is not a discipline, or when nothing extends
    /// it — there is no question to answer and no tier to draw.
    ///
    /// `utterance` is what the person actually said, and it is used for ONE
    /// thing: to throw out an assertion that rests on a word the discipline
    /// itself owns. See `assertionIsOnlyDisciplineVocabulary`.
    public static func resolve(
        for skill: AbilityRuntimeSkill,
        snapshot: AbilityRuntimeSnapshot,
        assertedApplicationIDs: Set<String> = [],
        utterance: String? = nil,
        ledger: ApplicationHabitLedger = .shared,
        now: Date = Date()
    ) -> Verdict? {
        let discipline = skill.ability.id
        let expertise = snapshot.expertiseAbilities(for: skill)
        guard !expertise.isEmpty else { return nil }

        let weights = ledger.weights(for: discipline, now: now)
        let total = weights.values.reduce(0, +)
        var asserted = Set(assertedApplicationIDs.map { $0.lowercased() })
        if let utterance {
            let vocabulary = disciplineVocabulary(discipline, snapshot: snapshot)
            asserted = asserted.filter { applicationID in
                !assertionIsOnlyDisciplineVocabulary(
                    applicationID: applicationID, utterance: utterance,
                    disciplineVocabulary: vocabulary, snapshot: snapshot)
            }
        }

        var candidates: [Candidate] = expertise.compactMap { abilityID in
            guard let applicationID = snapshot.applicationID(ofExpertise: abilityID)
            else { return nil }
            let record = snapshot.records.first { $0.package.ability.id == abilityID }
            let weight = weights[abilityID] ?? 0
            return Candidate(
                expertiseID: abilityID,
                applicationID: applicationID,
                title: record?.package.ability.title ?? abilityID.rawValue,
                tint: record?.package.ability.tint ?? "",
                weight: weight,
                share: total > 0 ? weight / total : 0,
                lastSeen: ledger.lastSeen(
                    discipline: discipline, expertise: abilityID, now: now),
                preference: record?.package.ability.routing.preference ?? 0,
                standing: .staticPreference)
        }
        guard !candidates.isEmpty else { return nil }

        // Ranking: habit first, then the packages' own declared standing, then
        // id — the same "stable across launches" rule the reverse index sorts by.
        candidates.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.preference != $1.preference { return $0.preference > $1.preference }
            return $0.expertiseID.rawValue < $1.expertiseID.rawValue
        }

        // A LEAD IS NOT A TIE. Two players used equally often is a genuine
        // ambiguity in the habit, and falling through to declared preference
        // is more honest than breaking it on float noise.
        let leader = candidates[0]
        let runnerUpWeight = candidates.dropFirst().first?.weight ?? 0
        let hasHabit = leader.weight > 0 && leader.weight > runnerUpWeight
        // A standing describes the ROW, not its rank: a player this person has
        // never once used reads as "no history", never as "less used", however
        // far ahead the leader is.
        for index in candidates.indices {
            if candidates[index].weight <= 0 {
                candidates[index].standing = .staticPreference
            } else if hasHabit, index == 0 {
                candidates[index].standing = .habitual
            } else {
                candidates[index].standing = .fallback
            }
        }

        // The words win outright when they name exactly one of these players.
        var chosenIndex = 0
        let named = candidates.indices.filter {
            asserted.contains(candidates[$0].applicationID.lowercased())
        }
        if named.count == 1 {
            chosenIndex = named[0]
            candidates[chosenIndex].standing = .asserted
        }
        // Nothing named and no habit: index 0 is already the highest declared
        // preference, because the sort above falls through to it.
        let chosen = candidates[chosenIndex]
        if named.count == 1 {
            // An asserted pick sorts to the front so the tier reads top-down.
            candidates.remove(at: chosenIndex)
            candidates.insert(chosen, at: 0)
        }
        return Verdict(
            disciplineID: discipline, candidates: candidates, chosen: chosen)
    }

    /// Every word the DISCIPLINE answers to — its own aliases and trigger
    /// vocabulary. "music" is multimedia's, not any one player's.
    private static func disciplineVocabulary(
        _ discipline: AbilityID, snapshot: AbilityRuntimeSnapshot
    ) -> Set<String> {
        guard let package = snapshot.records.first(where: {
            $0.package.ability.id == discipline
        })?.package else { return [] }
        return Set(
            (package.ability.aliases
                + package.ability.triggers.tokens
                + package.ability.triggers.phrases)
                .map { $0.lowercased() })
    }

    /// A WORD THE DISCIPLINE OWNS CANNOT NAME ONE OF ITS PLAYERS.
    ///
    /// `apple-music` declares the alias "music", and so does `multimedia` —
    /// so "pause the music" reads, to the ordinary mention test, as though the
    /// person had said "Apple Music". Left alone that is fatal to the whole
    /// point of ranking by habit: the shared word would name Apple Music on
    /// every single turn, the assertion would outrank the tally forever, and
    /// someone who had moved to another player would never be followed there.
    ///
    /// So an assertion is thrown out when the sentence carries only vocabulary
    /// the discipline itself claims and none of the player's OWN names
    /// ("apple music", "itunes"). Saying the player's name still wins
    /// outright; saying "the music" now correctly asserts nothing.
    private static func assertionIsOnlyDisciplineVocabulary(
        applicationID: String,
        utterance: String,
        disciplineVocabulary: Set<String>,
        snapshot: AbilityRuntimeSnapshot
    ) -> Bool {
        guard let package = snapshot.records.first(where: {
            $0.package.applicationAffinities.contains {
                $0.id.lowercased() == applicationID
            }
        })?.package else { return false }
        let names = Set(
            (package.ability.aliases
                + (package.plugin?.application.aliases ?? [])
                + package.applicationAffinities.map(\.title)
                + [package.ability.title])
                .map { $0.lowercased() }
                .filter { !$0.isEmpty })
        let said = " " + utterance.lowercased() + " "
        func mentions(_ term: String) -> Bool {
            said.contains(" " + term + " ")
                || said.contains(" " + term + ",")
                || said.contains(" " + term + ".")
        }
        let distinctive = names.subtracting(disciplineVocabulary)
        // Named by one of its own names — a real naming, keep the assertion.
        if distinctive.contains(where: mentions) { return false }
        // Named only by a word the discipline also answers to — not a naming.
        return names.intersection(disciplineVocabulary).contains(where: mentions)
    }

    /// The habit a finished dispatch PROVES, or nil when it proves nothing.
    ///
    /// Attribution is evidence-first: what the adapter says it acted on, then
    /// the turn's frozen provider choice, then the Skill's own statically
    /// selected binding. An `app` ARGUMENT is never enough on its own — it
    /// says where the caller aimed, and a turn that aimed at a player which
    /// was not running must not be recorded as having used it.
    public static func habit(
        proving runtime: AbilityRuntimeSkill,
        outcome: SkillOutcome,
        providerApplicationID: String?,
        snapshot: AbilityRuntimeSnapshot,
        now: Date = Date()
    ) -> ApplicationHabit? {
        let discipline = runtime.ability.id
        let expertise = snapshot.expertiseAbilities(for: runtime)
        guard !expertise.isEmpty else { return nil }
        let landed = outcome.applicationID
            ?? providerApplicationID
            ?? snapshot.applicationID(of: runtime)
        guard let landed, !landed.isEmpty else { return nil }
        let wanted = landed.lowercased()
        guard let matched = expertise.first(where: {
            snapshot.applicationID(ofExpertise: $0)?.lowercased() == wanted
        }) else { return nil }
        return ApplicationHabit(
            disciplineID: discipline,
            expertiseID: matched,
            applicationID: snapshot.applicationID(ofExpertise: matched) ?? landed,
            skillID: runtime.skill.id.rawValue,
            observedAt: now)
    }
}
