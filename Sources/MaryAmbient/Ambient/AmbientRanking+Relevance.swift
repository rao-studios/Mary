//
//  AmbientRanking+Relevance.swift
//

import Foundation

extension AmbientRanker {

    // MARK: - Relevance

    /// Words worth matching on — everything else is grammar the document does
    /// not share. Internal (was private) so `AmbientAddressProbe` can apply
    /// the SAME notion of "a word that distinguishes something" when it
    /// decides whether an observed title is distinctive enough to address its
    /// application; two spellings of that judgement would drift.
    ///
    /// PUBLIC (was internal) for the same reason one rung further out:
    /// `AffordanceResolver` lives in MaryAdapter, because resolving a
    /// goal against what is on screen needs the Accessibility reading this
    /// package deliberately does not have — and it must ask exactly this
    /// question when it decides whether a control's label shares anything
    /// distinctive with the phrase, or merely shares "the".
    public static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at",
        "for", "with", "about", "is", "are", "was", "were", "it", "this",
        "that", "these", "those", "my", "your", "our", "their", "me", "you",
        "i", "we", "they", "he", "she", "what", "which", "who", "how", "do",
        "does", "did", "can", "could", "would", "should", "please", "read",
        "tell", "say", "says", "said", "show", "give", "again", "just", "so",
    ]

    /// Does the utterance CONCERN this eyeless source? The expansion trigger
    /// for the standing line: token overlap against the fact's own words, its
    /// subject and the source's name ("calendar", "reminders"). The same
    /// signal `relevance` already scores on, asked as a yes/no because the
    /// rendering decision is a yes/no.
    ///
    /// Deliberately NOT a numeric threshold on `relevance`: that score carries
    /// a recency term worth up to +1.0, so a digest refreshed thirty seconds
    /// ago would clear any threshold set low enough to be useful — which is
    /// how a courtesy line ends up spending the whole block budget on a turn
    /// that had nothing to do with it.
    public static func concernsEyeless(_ fact: AmbientFact, utterance: String) -> Bool {
        // A LIVE, currently-held perception (a `.applications` highlight, so far
        // the only case) is not a standing digest — it only exists in the
        // store while the user has something ACTUALLY selected right now
        // (`replacePerceived` wipes it within one poll tick otherwise), so
        // deixis ("this", "here", "on screen") is exactly the phrasing this
        // fact exists to answer — the same way it already is for a focused
        // workspace world (`isDeictic`, used by `concernsFocusedWorld` above).
        // Gated on `isPerceived` so it can never fire for a `.digest`/
        // `.namedRead` fact — both are `!isPerceived`, so this is inert for
        // calendar/reminders-style standing lines today.
        if fact.slot.isPerceived, isDeictic(utterance) { return true }
        let wanted = tokens(utterance)
        guard !wanted.isEmpty else { return false }
        // THE PLACE'S TOKEN AND NAME. With the world's, a Sketch fact's
        // haystack read `other_apps Applications`, so "sketch the logo" could not
        // match the very fact it was asking about — the fact was held, ranked
        // last, and never surfaced.
        var searchable = fact.content + " " + (fact.subject ?? "")
            + " " + fact.place.token + " " + fact.place.displayName
        if case .namedRead(_, let phrase) = fact.slot { searchable += " " + phrase }
        return !wanted.intersection(tokens(searchable)).isEmpty
    }

    public static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// How much this fact has to do with what the user just said. Deliberately
    /// simple and total: token overlap, plus the standing doctrine as small
    /// additive terms — the user's own request outranks a passive observation,
    /// live perception outranks cached text, and a stale fact loses ground
    /// without disappearing.
    public static func relevance(
        of fact: AmbientFact, to utterance: String, at now: Date = Date()
    ) -> Double {
        let wanted = tokens(utterance)
        var score = 0.0
        if !wanted.isEmpty {
            var searchable = fact.content + " " + (fact.subject ?? "")
            if case .namedRead(_, let phrase) = fact.slot { searchable += " " + phrase + " " + phrase }
            let have = tokens(searchable)
            let hits = wanted.intersection(have).count
            score += 3.0 * Double(hits)
        }
        // The user ASKED for this — the strongest statement of intent there is.
        if fact.registration == .askedFor { score += 1.5 }
        // LIVE perception outranks retrieval; cached words earn less.
        switch fact.provenance {
        case .liveAX:     score += 0.75
        case .recipeRead: score += 0.5
        case .cachedBody: score += 0.25
        case .derived:    break
        }
        // Recency, gently — the store is the memory of the MOMENT.
        score += 1.0 / (1.0 + fact.age(at: now) / 60.0)
        // Past its window it keeps its place and loses its authority.
        if !fact.isFresh(at: now) { score -= 0.5 }
        return score
    }

    /// Rank facts under the user's three-way rule. Focus priority is a
    /// PARTITION, not a bonus: a focused-place fact never sorts below an
    /// unfocused one in that mode, however relevant the other is — which is
    /// what "apply focused priority INSTEAD" means.
    ///
    /// PLACES, NOT WORLDS. Bonnie offered a world-typed shim beside this that
    /// wrapped its argument in `.lane(...)`, which worked while a world WAS
    /// an application. Here every application shares the one `.applications`
    /// lane, so comparing worlds would rank every application as focused
    /// whenever any of them was — the shim is not narrower, it is wrong, and
    /// so it is gone.
    public static func rank(
        facts: [AmbientFact],
        utterance: String,
        focusedPlace: AmbientPlace?,
        attention: AmbientAttention? = nil,
        at now: Date = Date()
    ) -> (mode: AmbientRankingMode, facts: [AmbientFact]) {
        let attention = attention?.isFresh(at: now) == true && attention?.isDirectReference == true
            ? attention : nil
        let mode = mode(utterance: utterance, focusedPlace: focusedPlace)
        let scored = facts.map { (fact: $0, score: relevance(of: $0, to: utterance, at: now)) }
        let sorted = scored.sorted { lhs, rhs in
            let lhsAttended = attention?.matches(lhs.fact) == true
            let rhsAttended = attention?.matches(rhs.fact) == true
            if lhsAttended != rhsAttended { return lhsAttended }
            if mode == .focusedWorld, let focusedPlace {
                let lhsFocused = lhs.fact.place == focusedPlace
                let rhsFocused = rhs.fact.place == focusedPlace
                if lhsFocused != rhsFocused { return lhsFocused }
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Deterministic tie-break: newer first, then the stable key order.
            if lhs.fact.capturedAt != rhs.fact.capturedAt {
                return lhs.fact.capturedAt > rhs.fact.capturedAt
            }
            return AmbientContextStore.ordered(lhs.fact, rhs.fact)
        }
        return (mode, sorted.map(\.fact))
    }

    /// RANK, THEN RENDER. `alreadyRendered` names the facts the caller has
    /// already put in front of the model in FULL (the leading world's live
    /// section) — they are skipped here rather than mentioned, because they
    /// are not omitted, they are above.
    ///
    /// `surfaces` IS TIER 0 AND SPENDS FIRST — the caller passes them
    /// lead-lane first (it is the side holding `leadPlace`; this stays
    /// place-ignorant). The foundation is charged to the budget before any
    /// detail, which is the tiering made literal. A surface that does not
    /// fit is DROPPED rather than degraded to a mention: it is live
    /// perception, not held knowledge, and a half-rendered screen claims
    /// something no one measured.
    public static func render(
        facts: [AmbientFact],
        utterance: String,
        focusedPlace: AmbientPlace?,
        attention: AmbientAttention? = nil,
        alreadyRendered: Set<AmbientKey> = [],
        suppressingContentIn suppressed: [String] = [],
        surfaces: [AmbientSurface] = [],
        budget: Int = voiceBudget,
        maxBlocks: Int = maxBlocks,
        at now: Date = Date()
    ) -> AmbientRendering {
        let attention = attention?.isFresh(at: now) == true && attention?.isDirectReference == true
            ? attention : nil
        let candidates = facts.filter { fact in
            let attended = attention?.matches(fact) == true
            guard attended || !alreadyRendered.contains(fact.key) else { return false }
            guard !fact.content.isEmpty else { return false }
            // The turn's own fetch-first passage rides its own authority
            // block; rendering it twice would put the same text under two
            // different freshness claims — the exact hazard the ONE-authority
            // ordering exists to close.
            return !suppressed.contains { $0.contains(fact.content) }
        }
        let ranked = rank(
            facts: candidates,
            utterance: utterance,
            focusedPlace: focusedPlace,
            attention: attention,
            at: now)
        var rendering = AmbientRendering(mode: ranked.mode)
        var spent = 0
        // TIER 0 FIRST, in the caller's order (lead lane leading).
        for surface in surfaces where surface.isFresh(at: now) {
            let line = surface.surfaceLine(at: now)
            guard spent + line.count <= budget else { continue }
            rendering.surfaceLines.append(line)
            spent += line.count
        }
        for fact in ranked.facts {
            rendering.keys.append(fact.key)
            let attended = attention?.matches(fact) == true
            let focusable = fact.place.focus != nil
            let eyelessAside = !focusable
                && fact.registration != .askedFor
                && !concernsEyeless(fact, utterance: utterance)
            // A direct selection is the user's explicit referent, even outside
            // the leading world. Other background perception stays a mention.
            let mentionOnly = !attended && ((fact.slot.isPerceived && focusable && fact.place != focusedPlace)
                || eyelessAside
            )
            let block = fact.block(at: now, limit: max(0, budget - spent))
            let roomForBlock = !mentionOnly && (
                rendering.blocks.isEmpty
                    || (rendering.blocks.count < maxBlocks && spent + block.count <= budget))
            if roomForBlock {
                rendering.blocks.append(block)
                spent += block.count
            } else {
                rendering.mentions.append(fact.mentionLine(at: now))
            }
        }
        return rendering
    }

}
