//
//  ReferenceFocus.swift
//  MaryBrain
//
//  WHAT: Impure gatherer — watcher boxes and container registry → one answer.
//  OUT:  ReferenceResolver (pure) → AmbientContextStore.noteReference
//  PIN:  Xcode lane must not be impacted: resolve answers nil unless all three guards hold.
//

import Foundation

/// WHAT KIND OF ACT IS ABOUT TO HAPPEN to the container. THE POINT OF THIS TYPE: the same
/// words deserve different answers. Getting "read the other one" wrong costs a re-read;
/// getting "delete the Tuesday line in the other one" wrong destroys the wrong note's line.
public enum ReferenceAct: Sendable, Equatable {
    /// No edit intent — a question, a read, a listing.
    case read
    /// `.replace` / `.insert`. Reversible: `revert_last_edit` covers it.
    case revise
    /// `.delete` / `.move`. A move counts because it removes from the source.
    case destroy

    /// The mapping, in one place.
    public static func from(_ shape: EditIntent.Shape?) -> ReferenceAct {
        switch shape {
        case .none:                 return .read
        case .replace?, .insert?:   return .revise
        case .delete?, .move?:      return .destroy
        }
    }
}

/// THE ANSWER: which container this turn means, and how we know.
public struct ResolvedReferent: Sendable, Equatable {
    /// WHERE the referred-to container lives. A place, so a taught
    /// application's `[D#]` is a referent in its own right rather than one of
    /// however many are riding the `.applications` host lane.
    public var place: AmbientPlace
    /// The place's own `documentKey` — the same string its `PassageBacking`
    /// answers `bodyForDocument` for.
    public var key: String
    /// What the user would call it.
    public var title: String
    public var rung: ReferenceResolver.Rung
    public var confidence: ReferenceResolver.Confidence
    /// The rival, when a rule had to pick. What a correction re-aims AT.
    public var alternative: ReferenceResolver.Rival?

    public init(
        place: AmbientPlace, key: String, title: String,
        rung: ReferenceResolver.Rung,
        confidence: ReferenceResolver.Confidence = .exact,
        alternative: ReferenceResolver.Rival? = nil
    ) {
        self.place = place
        self.key = key
        self.title = title
        self.rung = rung
        self.confidence = confidence
        self.alternative = alternative
    }

    /// The built-in spelling.
    public init(
        attention: AmbientAttention, key: String, title: String,
        rung: ReferenceResolver.Rung,
        confidence: ReferenceResolver.Confidence = .exact,
        alternative: ReferenceResolver.Rival? = nil
    ) {
        self.init(
            place: .lane(attention), key: key, title: title, rung: rung,
            confidence: confidence, alternative: alternative)
    }
}

/// WHAT THE TURN GOT — a container, nothing, or a refusal.
public enum ReferenceDecision: Sendable, Equatable {
    /// Nothing referred to a container. The one in front is right.
    case none
    case referent(ResolvedReferent)
    /// A reference was made, could not be settled, and the act is destructive.
    case refused(String)

    /// The container, when there is one. Nil for both other cases, so a caller
    /// that only wants "which one" needs no new branch.
    public var referent: ResolvedReferent? {
        guard case .referent(let found) = self else { return nil }
        return found
    }
}

public enum ReferenceFocus {

    /// WHICH CONTAINER THIS TURN MEANS, across every enrolled world. `lead` is the world the
    /// arbiter gave the turn to; a container there is deliberately NOT a referent (guarantee
    /// clause 2).
    public static func resolve(
        utterance: String,
        rosters: [ContainerRoster],
        lead: AmbientPlace?,
        registry: ContainerRegistry = .shared,
        now: Date = Date()
    ) -> ResolvedReferent? {
        decide(
            utterance: utterance, act: .read, rosters: rosters, lead: lead,
            registry: registry, now: now).referent
    }

    /// WHICH CONTAINER, AND WHETHER THE ACT MAY PROCEED. The four-by-two matrix in one
    /// function. Everything in the REVERSIBLE column is silent.
    public static func decide(
        utterance: String,
        act: ReferenceAct,
        rosters: [ContainerRoster],
        lead: AmbientPlace?,
        registry: ContainerRegistry = .shared,
        now: Date = Date()
    ) -> ReferenceDecision {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return .none }

        // GUARANTEE CLAUSE 3, checked first and cheapest. A coding cue means this whole mechanism
        // stands down — "replace this function's body" must never be hijacked to a note because a
        // note was mentioned two turns ago. The cue is now the coding package's
        // own corpus rather than a list of words someone remembered to add.
        guard AmbientRanker.namedDiscipline(in: said) != .coding
        else { return .none }

        var candidates: [ReferenceResolver.Candidate] = []
        var listing: [String]?
        var listingIsNewest = false

        for roster in rosters {
            // GUARANTEE CLAUSE 2: the leading world's containers are not
            // referents. Its seams already answer correctly.
            guard roster.place != lead else { continue }
            let rows = roster.cached()
            guard !rows.isEmpty else { continue }

            let keys = rows.map(\.key)
            let ranks = registry.salienceRanks(place: roster.place, keys: keys, at: now)
            if let remembered = registry.listing(for: roster.place, against: keys) {
                // ONE LISTING AT A TIME. Two worlds both holding a live listing would make "the second
                // one" ambiguous across worlds, and the honest answer to an ambiguous ordinal is to
                // abstain — so the first live listing wins and a second one cancels both.
                if listing == nil {
                    listing = remembered.keys
                    listingIsNewest = isNewestEvidence(
                        remembered, place: roster.place, registry: registry, now: now)
                } else {
                    listing = nil
                    listingIsNewest = false
                }
            }

            candidates += rows.map { row in
                ReferenceResolver.Candidate(
                    place: roster.place,
                    key: row.key,
                    handle: registry.handle(
                        place: roster.place, prefix: roster.handlePrefix, key: row.key),
                    title: row.title,
                    subtitle: row.subtitle,
                    body: row.body,
                    listIndex: row.listIndex,
                    isFront: row.isFront,
                    salience: ranks[row.key])
            }
        }

        switch ReferenceResolver.outcome(
            utterance: said,
            candidates: candidates,
            listing: listing,
            listingIsNewestEvidence: listingIsNewest) {

        case .none:
            // GUARANTEE CLAUSE 1. Nothing referred to a container, so the one
            // in front is not a guess — it is the reading they meant.
            return .none

        case .resolved(let choice):
            // GUARANTEE CLAUSE 2.6 — THE RIVAL-WRITING BAR. Coding-lead and no-lead turns are
            // byte-identical through here (`lead?.focus == .writing` is the key), so the Xcode
            // guarantee and "add this to my sourdough note" while coding both stand.
            if lead?.focus == .writing,
               choice.place.focus == .writing,
               choice.place != lead {
                let crossesOnEvidence = choice.confidence == .exact
                    && choice.rung != .content
                guard crossesOnEvidence else { return .none }
            }
            let title = candidates.first { $0.key == choice.key }?.title ?? ""
            return .referent(ResolvedReferent(
                place: choice.place, key: choice.key, title: title,
                rung: choice.rung, confidence: choice.confidence,
                alternative: choice.alternative))

        case .ambiguous(let phrase, let rivals):
            // GUARANTEE CLAUSE 4. A reference WAS made and could not be settled. Reversible: behave
            // exactly as before.
            guard act == .destroy else { return .none }
            return .refused(refusal(phrase: phrase, rivals: rivals))
        }
    }

    /// THE ONE NEW SENTENCE, in the tree's established refusal style: state what is ambiguous
    /// and the ONE fact that would settle it, then stop. No question mark and no imperative.
    public static func refusal(phrase: String, rivals: [ReferenceResolver.Rival]) -> String {
        let count = SpokenPhrase.countWord(rivals.count)
        // NAMED, not counted, when the list is short enough to say — a name is
        // what settles it, and the user cannot act on a number.
        if rivals.count <= 3 {
            let names = rivals.map(\.title).joined(separator: ", ")
            return "\"\(phrase)\" could be \(names), and I won't take one of them out on a "
                + "guess. Naming it settles it."
        }
        return "\"\(phrase)\" matches \(count) of the things you have open, and I won't take "
            + "one of them out on a guess. The title, or a few words from it, settles it."
    }

    /// APPLY A ONE-WORD CORRECTION, and return what it re-aimed to. THE THIRD CLAUSE OF THE
    /// DOCTRINE, mechanized. Called when `MaryBrain.bareCorrection` fires and the PREVIOUS turn
    /// produced a referent — there is nothing to correct otherwise.
    @discardableResult
    public static func applyCorrection(
        to previous: ResolvedReferent,
        rosters: [ContainerRoster],
        registry: ContainerRegistry = .shared,
        now: Date = Date()
    ) -> ReferenceResolver.Rival? {
        // The rival the resolver already picked between, when there was one;
        // otherwise the most salient other container in that world.
        let intended = previous.alternative ?? nextBest(
            after: previous, rosters: rosters, registry: registry, now: now)
        guard let intended else {
            // NOTHING TO RE-AIM TO. Demote the rejected one anyway — "not that
            // one" is still information, and the next anaphoric pick must stop
            // preferring it even when we cannot say what they did mean.
            registry.noteCorrection(
                place: previous.place, rejected: previous.key, intended: previous.key, at: now)
            registry.noteEvidence(place: previous.place, key: previous.key, .shown, at: now)
            return nil
        }
        registry.noteCorrection(
            place: intended.place, rejected: previous.key, intended: intended.key, at: now)
        return intended
    }

    /// The most salient container in the same place that is NOT the rejected
    /// one — the fallback when the pick had no explicit runner-up.
    public static func nextBest(
        after previous: ResolvedReferent,
        rosters: [ContainerRoster],
        registry: ContainerRegistry,
        now: Date
    ) -> ReferenceResolver.Rival? {
        guard let roster = rosters.first(where: { $0.place == previous.place })
        else { return nil }
        let rows = roster.cached().filter { $0.key != previous.key }
        guard !rows.isEmpty else { return nil }
        if rows.count == 1 {
            return .init(place: previous.place, key: rows[0].key, title: rows[0].title)
        }
        let ranks = registry.salienceRanks(
            place: previous.place, keys: rows.map(\.key), at: now)
        guard let best = rows
            .filter({ ranks[$0.key] != nil })
            .min(by: { (ranks[$0.key] ?? .max) < (ranks[$1.key] ?? .max) })
        else { return nil }
        return .init(place: previous.place, key: best.key, title: best.title)
    }

    /// NEWEST EVIDENCE WINS — the rule for "the last one". An ordinal takes a roster row only
    /// while the listing is the most recent referential event. Once Mary has acted on, read, or
    /// spoken about one of those containers more recently, "the last one" means THAT.
    public static func isNewestEvidence(
        _ listing: ContainerListing,
        place: AmbientPlace,
        registry: ContainerRegistry,
        now: Date
    ) -> Bool {
        let referential: Set<ContainerEvidence> = [
            .corrected, .actedOn, .read, .spokenAbout,
        ]
        for key in listing.keys {
            if registry.hasEvidence(
                place: place,
                key: key,
                kinds: referential,
                newerThan: listing.at,
                at: now) {
                return false
            }
        }
        return true
    }
}
