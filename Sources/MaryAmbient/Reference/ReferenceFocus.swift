//
//  ReferenceFocus.swift
//  MaryBrain
//
//  THE IMPURE GATHERER: reads the watcher boxes and the container registry,
//  hands them to the pure `ReferenceResolver`, and publishes ONE answer.
//
//  `TextEditFocus` generalized. The split is by purity, which is what keeps the
//  ladder testable with nothing running: rows and salience come from here,
//  judgement happens there.
//
//  ═══════════════════════════════════════════════════════════════════════
//  THE XCODE GUARANTEE — the constraint this file is built around.
//
//  The user's words: "This really needs to be thought out so it doesn't impact
//  XCode's lane of thinking."
//
//  So `resolve` answers nil unless ALL THREE hold:
//
//    1. THE RESOLVER FIRED at a rung that names a container. Abstention — the
//       common case, most turns — is nil.
//    2. THE CONTAINER IS NOT IN THE LEADING WORLD. A turn about the document
//       already leading needs no referent; the seams' existing answer is
//       already right, and replacing it with an identical one is a way to be
//       subtly wrong for no gain.
//    3. THE UTTERANCE NAMES NO CODING TARGET. `classifyOverride` already
//       recognises "function", "build", "refactor", "compile" and the rest;
//       if it says `.coding`, this rung stands down entirely.
//
//  Everything the guarantee buys follows from that being nil on an Xcode turn:
//  `focusProvider` is untouched, so the roster hoist and `fuzzyOrder` are
//  unchanged and a half-remembered Skill name still resolves; Xcode never
//  becomes a referent target, so it gains no fetch-first and no locate — which
//  matters because gaining locate would make `RevisionVeto` start redirecting
//  Xcode `type_at_cursor` calls to `replace_passage`, the one change that would
//  visibly alter how coding feels.
//
//    4. THE ACT IS NOT DESTRUCTIVE WITH AN UNSETTLED REFERENCE. See `decide`:
//       a `.destroy` act whose container reference could not be settled
//       resolves to a REFUSAL rather than to a container. This clause never
//       fires on a coding turn (clause 3 already returned), so it takes nothing
//       away from Xcode; it only stops a destructive act falling through to
//       whatever happens to be in front.
//
//  Pinned by `ReferenceFocusTests.theXcodeLaneIsUntouched`.
//  ═══════════════════════════════════════════════════════════════════════
//

import Foundation

/// WHAT KIND OF ACT IS ABOUT TO HAPPEN to the container.
///
/// THE POINT OF THIS TYPE: the same words deserve different answers. Getting
/// "read the other one" wrong costs a re-read; getting "delete the Tuesday line
/// in the other one" wrong destroys the wrong note's line. Until this existed,
/// the resolver could not tell them apart — `EditIntent.shape` is computed 54
/// lines before the referent and was thrown away, and the seam was
/// `() -> ResolvedReferent?` with no argument position to carry it.
///
/// Derived from `EditIntent.Shape`, which rests on the tweak allowlist's own
/// reasoning: the passage verbs are `.tweak` because `revert_last_edit` is the
/// way back, and a delete is the one whose way back is thinnest.
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
    /// WHERE the referred-to container lives. A realm, so a taught
    /// application's `[D#]` is a referent in its own right rather than one of
    /// however many are riding the `.applications` host lane.
    public var place: AmbientRealm
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
        place: AmbientRealm, key: String, title: String,
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
        world: AmbientWorld, key: String, title: String,
        rung: ReferenceResolver.Rung,
        confidence: ReferenceResolver.Confidence = .exact,
        alternative: ReferenceResolver.Rival? = nil
    ) {
        self.init(
            place: .native(world), key: key, title: title, rung: rung,
            confidence: confidence, alternative: alternative)
    }
}

/// WHAT THE TURN GOT — a container, nothing, or a refusal.
public enum ReferenceDecision: Sendable, Equatable {
    /// Nothing referred to a container. The one in front is right.
    case none
    case referent(ResolvedReferent)
    /// A reference was made, could not be settled, and the act is destructive.
    /// The sentence states what is ambiguous and the one fact that would settle
    /// it, then stops — `PassageResolver.refusal`'s rule, and pinned as a class
    /// by `PassageTests.noPassageRefusalReadsAsAnErrand`.
    case refused(String)

    /// The container, when there is one. Nil for both other cases, so a caller
    /// that only wants "which one" needs no new branch.
    public var referent: ResolvedReferent? {
        guard case .referent(let found) = self else { return nil }
        return found
    }
}

public enum ReferenceFocus {

    /// WHICH CONTAINER THIS TURN MEANS, across every enrolled world.
    ///
    /// `lead` is the world the arbiter gave the turn to; a container there is
    /// deliberately NOT a referent (guarantee clause 2).
    ///
    /// Pure given its inputs — the rosters are handed in — so the whole
    /// guarantee is testable as a table with no application running.
    /// The old shape, unchanged for every caller that only wants "which one".
    /// A refusal reads as nil here, which is today's behaviour.
    public static func resolve(
        utterance: String,
        rosters: [ContainerRoster],
        lead: AmbientRealm?,
        registry: ContainerRegistry = .shared,
        now: Date = Date()
    ) -> ResolvedReferent? {
        decide(
            utterance: utterance, act: .read, rosters: rosters, lead: lead,
            registry: registry, now: now).referent
    }

    /// WHICH CONTAINER, AND WHETHER THE ACT MAY PROCEED.
    ///
    /// The four-by-two matrix in one function. Everything in the REVERSIBLE
    /// column is silent — including the no-evidence fallback to the container in
    /// front, which is the *obvious* reading and does not need narrating. The
    /// only new sentence in the system is the destructive refusal.
    public static func decide(
        utterance: String,
        act: ReferenceAct,
        rosters: [ContainerRoster],
        lead: AmbientRealm?,
        registry: ContainerRegistry = .shared,
        now: Date = Date()
    ) -> ReferenceDecision {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return .none }

        // GUARANTEE CLAUSE 3, checked first and cheapest. A coding cue means
        // this whole mechanism stands down — "replace this function's body"
        // must never be hijacked to a note because a note was mentioned two
        // turns ago.
        guard FocusOverride.classifyOverride(utterance: said) != .coding
        else { return .none }

        var candidates: [ReferenceResolver.Candidate] = []
        var listing: [String]?
        var listingIsNewest = false

        for roster in rosters {
            // GUARANTEE CLAUSE 2: the leading world's containers are not
            // referents. Its seams already answer correctly.
            guard roster.realm != lead else { continue }
            let rows = roster.cached()
            guard !rows.isEmpty else { continue }

            let keys = rows.map(\.key)
            let ranks = registry.salienceRanks(realm: roster.realm, keys: keys, at: now)
            if let remembered = registry.listing(for: roster.realm, against: keys) {
                // ONE LISTING AT A TIME. Two worlds both holding a live listing
                // would make "the second one" ambiguous across worlds, and the
                // honest answer to an ambiguous ordinal is to abstain — so the
                // first live listing wins and a second one cancels both.
                if listing == nil {
                    listing = remembered.keys
                    listingIsNewest = isNewestEvidence(
                        remembered, realm: roster.realm, registry: registry, now: now)
                } else {
                    listing = nil
                    listingIsNewest = false
                }
            }

            candidates += rows.map { row in
                ReferenceResolver.Candidate(
                    realm: roster.realm,
                    key: row.key,
                    handle: registry.handle(
                        realm: roster.realm, prefix: roster.handlePrefix, key: row.key),
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
            // GUARANTEE CLAUSE 2.6 — THE RIVAL-WRITING BAR. On a WRITING-led
            // turn, a referent in a DIFFERENT writing world crosses only on
            // strong evidence: an exact hit on a rung where the user actually
            // named or pointed at the thing (handle, title, subtitle, an
            // ordinal against a listing they saw, real anaphora). A content
            // hit — one distinctive word shared with some open note's body —
            // or any rule-chosen pick stays home.
            //
            // THE FAILURE THIS FIXES (live, in Pages): only Scrivener and
            // TextEdit enroll container rosters, so on a Pages-led turn this
            // resolver can ONLY ever answer with a rival writing world — and
            // its answer sits above frontmost in `resolveWorld`. One
            // incidental word shared with an open TextEdit note title was
            // enough to hijack an unqualified passage verb out of the
            // document the user was actually working in. Publication is the
            // one altitude that covers every consumer at once —
            // `resolveWorld` rung 2.5, fetch-first, and the roster's
            // admitted-worlds set all read `ambient.referent()`.
            //
            // Coding-lead and no-lead turns are byte-identical through here
            // (`lead?.focus == .writing` is the key), so the Xcode guarantee
            // and "add this to my sourdough note" while coding both stand.
            if lead?.focus == .writing,
               choice.realm.focus == .writing,
               choice.realm != lead {
                let crossesOnEvidence = choice.confidence == .exact
                    && choice.rung != .content
                guard crossesOnEvidence else { return .none }
            }
            let title = candidates.first { $0.key == choice.key }?.title ?? ""
            return .referent(ResolvedReferent(
                place: choice.realm, key: choice.key, title: title,
                rung: choice.rung, confidence: choice.confidence,
                alternative: choice.alternative))

        case .ambiguous(let phrase, let rivals):
            // GUARANTEE CLAUSE 4. A reference WAS made and could not be
            // settled.
            //
            // Reversible: behave exactly as before — fall through to the
            // container in front, silently. Getting a read or a revision wrong
            // costs a re-read or a `revert_last_edit`, and narrating every
            // ambiguous pick is how narration stops being heard.
            //
            // Destructive: refuse. Measured live before this existed — "delete
            // the Tuesday line in the other one" with eight notes open abstained
            // to the front note and deleted the line from the WRONG one.
            guard act == .destroy else { return .none }
            return .refused(refusal(phrase: phrase, rivals: rivals))
        }
    }

    /// THE ONE NEW SENTENCE, in the tree's established refusal style: state what
    /// is ambiguous and the ONE fact that would settle it, then stop.
    ///
    /// No question mark and no imperative. `PassageResolver.refusal` and
    /// `PassageWriteError.ambiguousInDocument` are the precedents, and
    /// `PassageTests.noPassageRefusalReadsAsAnErrand` pins the class: a
    /// Skill-invoking model reads an imperative in a Skill result as a thing to go
    /// and do.
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

    /// APPLY A ONE-WORD CORRECTION, and return what it re-aimed to.
    ///
    /// THE THIRD CLAUSE OF THE DOCTRINE, mechanized. Called when
    /// `MaryBrain.bareCorrection` fires and the PREVIOUS turn produced a
    /// referent — there is nothing to correct otherwise.
    ///
    /// RE-AIM ONLY. What already landed stays where it landed; this makes the
    /// next command land in the right place. The decision was deliberate: an
    /// undo-and-redo pair can go half-done, and a correction should not be able
    /// to damage anything.
    ///
    /// The alternative is where it re-aims TO. That is why `Choice.alternative`
    /// is carried at all: without it a correction has nothing to name.
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
                realm: previous.place, rejected: previous.key, intended: previous.key, at: now)
            registry.noteEvidence(realm: previous.place, key: previous.key, .shown, at: now)
            return nil
        }
        registry.noteCorrection(
            realm: intended.realm, rejected: previous.key, intended: intended.key, at: now)
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
        guard let roster = rosters.first(where: { $0.realm == previous.place })
        else { return nil }
        let rows = roster.cached().filter { $0.key != previous.key }
        guard !rows.isEmpty else { return nil }
        if rows.count == 1 {
            return .init(realm: previous.place, key: rows[0].key, title: rows[0].title)
        }
        let ranks = registry.salienceRanks(
            realm: previous.place, keys: rows.map(\.key), at: now)
        guard let best = rows
            .filter({ ranks[$0.key] != nil })
            .min(by: { (ranks[$0.key] ?? .max) < (ranks[$1.key] ?? .max) })
        else { return nil }
        return .init(realm: previous.place, key: best.key, title: best.title)
    }

    /// NEWEST EVIDENCE WINS — the rule for "the last one".
    ///
    /// An ordinal takes a roster row only while the listing is the most recent
    /// referential event. Once Mary has acted on, read, or spoken about one of those
    /// containers more recently, "the last one" means THAT.
    ///
    /// `.shown` is deliberately not compared: minting handles is what a listing
    /// DOES, so it would always tie with its own evidence.
    public static func isNewestEvidence(
        _ listing: ContainerListing,
        realm: AmbientRealm,
        registry: ContainerRegistry,
        now: Date
    ) -> Bool {
        let referential: Set<ContainerEvidence> = [
            .corrected, .actedOn, .read, .spokenAbout,
        ]
        for key in listing.keys {
            if registry.hasEvidence(
                realm: realm,
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
