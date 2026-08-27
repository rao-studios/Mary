//
//  PassageWidening.swift
//  MaryBrain
//
//  "READ WIDER, THEN DECIDE ALONE." The user's rule, and the whole of this
//  file's job: given what they called it, find the piece of the document they
//  meant, and NEVER come back with "which one did you mean?".
//
//  Pure. No document, no app, no AX, no I/O — (target, body, units, attention)
//  in, a decision out. That is deliberate: the one part of a revision that has
//  to be RIGHT is the part that decides what gets overwritten, and a function
//  that can be tabled and pinned is the only kind of right that survives a
//  refactor.
//
//  A FIXED LADDER, STOP AT THE FIRST RUNG THAT YIELDS ANYTHING:
//
//    0 verbatim     the target's own words, exactly, in the body
//    1 structural   a unit LABEL — "Purpose section" → the section headed
//                   Purpose. This is the rung the live failure needed.
//    2 normalized   whitespace collapsed, punctuation stripped, case and
//                   diacritics folded
//    3 overlap      token overlap over paragraphs and sections, reusing
//                   `AmbientRanker.tokens`
//    4 widened      a FRAGMENT of the target found verbatim, then widened to
//                   the smallest block unit enclosing it
//
//  Stopping at the first rung matters as much as the rungs do. A ladder that
//  pooled every rung's hits would let a fuzzy token match outscore the exact
//  words the user just said, and the tie-break's first term — rung ascending —
//  would be the only thing standing between us and that. Two guards for one
//  invariant, on purpose.
//
//  BECAUSE SHE DECIDES UNATTENDED, the decision carries its own recoverability:
//  the runner-up is named, the confidence says how close it was, and the trace
//  says which rung fired. A wrong pick that names the alternative is one
//  sentence away from being right; a wrong pick that says nothing is the
//  Purpose section still standing.
//

import Foundation

public enum PassageWidening {

    // MARK: - The constants, and the arithmetic behind each

    /// Rung 3's floor: what fraction of the target's content words a paragraph
    /// or section must actually contain.
    ///
    /// HALF, and the arithmetic is the short targets people speak. "The
    /// Purpose section" is two content tokens after `AmbientRanker.tokens`
    /// drops "the" — so half means one of them, which is what makes the live
    /// case reachable at all. Four tokens means two. Below a half, a SINGLE
    /// incidental word carries the match, and "the batteries paragraph" lands
    /// on whichever paragraph mentions batteries in passing rather than the
    /// one about them.
    public static let minimumOverlap = 0.5

    /// How far ahead the winner must be to be `.chosen` rather than
    /// `.contested`.
    ///
    /// A QUARTER, measured in the same units as `overlap` — fractions of the
    /// target's content words. On a two-token target one extra word is worth
    /// 0.50, comfortably decisive; on a four-token target it is worth exactly
    /// 0.25, so one extra word is the boundary and the comparison is `<`,
    /// which makes "matched one more of your words" decisive and "matched
    /// exactly as many" contested. Two candidates that account for the same
    /// words are ALWAYS contested, which is the honest reading of a tie.
    public static let decisiveMargin = 0.25

    /// THE SAFETY VALVE ON DECIDING ALONE. A span WE widened to, larger than
    /// this, is refused and the narrower alternative named.
    ///
    /// 4000 characters is twice `AmbientFact.contentCap` (2000) — a span this
    /// size cannot even be held whole as an ambient fact, which means Mary
    /// could not read back to the user what she had just overwritten. Deciding
    /// alone is only defensible while the decision is reportable. Replacing
    /// four thousand characters unattended is not a surgical edit; it is the
    /// wholesale clobber the doctrine bans by name, arrived at by arithmetic
    /// instead of by intent.
    ///
    /// THE CAP IS ON OUR WIDENING, NOT ON THE USER'S OWN NAMING. A section
    /// they named by its heading is their instruction, however long it is
    /// (rung 1); a span we chose for them because their words were only a
    /// fragment is ours (rung 4), and ours is the one that has to justify
    /// itself.
    public static let maxSpan = 4000

    /// THE MISS, in the words this tree already uses. Quoted from
    /// `PagesPlugin.targetedOutcome` — one phrasing for one fact. A second
    /// wording for "I looked and it isn't in the body text" is precisely the
    /// drift that let the same miss be narrated three different ways.
    ///
    /// A Swift buffer has no headers or footers, so half this sentence is
    /// Pages-shaped in an Xcode turn. Kept anyway: the operative half — "or
    /// the wording differs" — is the same fact everywhere, and a per-world
    /// variant of a refusal is a per-world refusal, which is what "this
    /// paradigm should apply to all applications in the workspace world" rules
    /// out.
    public static let missReason =
        "Headers, footers, text boxes and table cells live outside body text, "
        + "so it may be there and unreadable this way — or the wording differs."

    /// The words that name A PART OF a document rather than naming one. "The
    /// Purpose section" is the heading `Purpose` plus a noun saying what kind
    /// of thing it is, and stripping that noun is the entire fix for the live
    /// failure. Kept tight on purpose: "Introduction" and "Summary" are real
    /// heading names and must never be stripped.
    public static let partNouns: Set<String> = [
        "section", "sections", "paragraph", "paragraphs", "para", "paras",
        "chapter", "chapters", "heading", "headings", "header", "part",
        "passage", "block", "bit", "clause", "sentence", "line", "lines",
        "function", "func", "method", "declaration", "decl",
    ]

    /// Determiners a spoken target starts with. Dropped so "the Purpose
    /// section" and "Purpose" reach the same place.
    public static let leadingDeterminers: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "its", "his", "her",
        "their", "whole", "entire",
    ]

    // MARK: - The ladder

    /// Find the piece of `body` that `target` names.
    ///
    /// `units` is whatever the world's structure reader produced. AN EMPTY
    /// ARRAY IS LEGAL: rungs 1 and 3 have nothing to match against and drop
    /// out, and rung 4's fragment stands un-widened. That is the honest
    /// behaviour for a world that can read text but not parse it — degraded,
    /// still useful, and never pretending to structure it cannot see.
    public static func locate(
        target: String,
        in body: String,
        units: [PassageUnit],
        attention: PassageAttention? = nil
    ) -> PassageDecision {
        var trace: [String] = []
        let wanted = cleanTarget(target)
        guard !body.isEmpty, !wanted.isEmpty else {
            trace.append(body.isEmpty ? "nothing to search" : "no target given")
            return refusal(target: target, trace: trace)
        }
        let anchor = attention?.anchor(in: body)
        trace.append(anchor.map { "attention anchored at \($0)" } ?? "no attention anchor")

        let folded = FoldedText(body)
        let structural = structuralTarget(wanted)

        var candidates: [PassageCandidate] = []

        // RUNG 0 — the user's own words, exactly.
        //
        // TWO PASSES, and the order matters. The literal target FIRST, so a
        // quoted whole sentence matches its own full stop and comes back as
        // the paragraph it is rather than as that paragraph minus one
        // character. Only if that finds nothing does the sentence-mark-stripped
        // form get a turn, which is what catches the trailing period a model
        // adds to "the Purpose section."
        let literal = trimTarget(target)
        candidates = named(verbatimCandidates(literal, in: body), units: units)
        if candidates.isEmpty, wanted != literal {
            candidates = named(verbatimCandidates(wanted, in: body), units: units)
        }
        trace.append("rung 0 verbatim: \(candidates.count)")

        // RUNG 1 — a unit's LABEL. THE RUNG THE LIVE FAILURE NEEDED: "replace
        // the Purpose section" reaches the section headed Purpose because
        // `structuralTarget` drops the trailing part-noun.
        if candidates.isEmpty {
            candidates = structuralCandidates(structural, units: units)
            trace.append("rung 1 structural (\"\(structural)\"): \(candidates.count)")
        }

        // RUNG 2 — the same words, allowing for spacing, punctuation, case and
        // diacritics. Word-boundary checked, because at this distance from the
        // literal "purpose" must not match inside "purposeful".
        if candidates.isEmpty {
            candidates = named(folded.candidates(for: wanted, rung: .normalized), units: units)
            trace.append("rung 2 normalized: \(candidates.count)")
        }

        // RUNG 3 — how much of what they said this paragraph or section
        // actually contains. `AmbientRanker.tokens` does the tokenizing, which
        // means ONE stopword list in this tree; a second one is the drift this
        // codebase refuses.
        if candidates.isEmpty {
            candidates = overlapCandidates(structural, in: body, units: units)
            trace.append("rung 3 token overlap (>= \(minimumOverlap)): \(candidates.count)")
        }

        // RUNG 4 — their words were only a FRAGMENT of what is written. Find
        // the longest run of them that is really there, then widen to the
        // smallest block unit enclosing it, which by construction begins where
        // a paragraph, section or declaration begins rather than mid-sentence.
        if candidates.isEmpty {
            candidates = widenedCandidates(wanted, folded: folded, units: units)
            trace.append("rung 4 widened: \(candidates.count)")
        }

        guard !candidates.isEmpty else {
            trace.append("no candidates on any rung")
            return refusal(target: target, trace: trace)
        }

        let ordered = candidates.sorted { precedes($0, $1, anchor: anchor) }
        let winner = ordered[0]
        // THE RUNNER-UP HAS TO BE A DIFFERENT ANSWER. Two candidates over the
        // SAME span are one answer nominated twice, and naming one as the
        // other's rival makes `confidence` report `.contested` about a pick
        // that nothing competed with — then the report offers the user, as the
        // alternative, the very span it just chose. Rung 4 no longer
        // manufactures those (see `widenedCandidates`), but a structure reader
        // that emits a section and a paragraph over one span would, and this
        // is the layer that must not care which reader it is talking to.
        let runnerUp = ordered.dropFirst().first { $0.range != winner.range }
        let confidence = confidence(winner: winner, runnerUp: runnerUp)
        trace.append(
            "picked \(winner.range.lowerBound)..<\(winner.range.upperBound) "
            + "at rung \(winner.rung.rawValue) (\(winner.rung.label)), \(confidence.rawValue)")

        // THE SAFETY VALVE. Only rung 4 can trip it — see `maxSpan`.
        if winner.rung == .widened, winner.range.count > maxSpan {
            trace.append("refused: widened span \(winner.range.count) > \(maxSpan)")
            var decision = refusal(
                target: target,
                trace: trace,
                sentence: "Going by \"\(String(wanted.prefix(40)))\" I'd be rewriting "
                    + "\(winner.range.count) characters, which is more than I'll change "
                    + "on my own. Tell me the heading, or give me the exact words, "
                    + "and I'll do just that piece.")
            decision.narrowerAlternative = winner.narrower
            return decision
        }

        return PassageDecision(
            span: winner.range,
            rung: winner.rung,
            confidence: confidence,
            runnerUp: runnerUp,
            trace: trace,
            refusal: nil,
            narrowerAlternative: winner.narrower,
            kind: winner.kind,
            label: winner.label)
    }

    // MARK: - The tie-break: A TOTAL ORDER

    /// FIVE TERMS, IN THIS ORDER, and the order is the point: `locate` must
    /// never return "ambiguous, ask the user", because the user's own rule is
    /// "read wider, then DECIDE ALONE". A partial order would leave ties, and
    /// a tie is a question.
    ///
    ///   1. RUNG ascending — an exact hit beats a fuzzy one, always. (Within a
    ///      single `locate` every candidate shares a rung, since the ladder
    ///      stops at the first that yields anything. The term is here because
    ///      the ORDER is the contract, not because this call site needs it.)
    ///   2. OVERLAP descending — more of what the user actually said.
    ///   3. NEAREST THE ATTENTION ANCHOR — when there is one. Skipped entirely
    ///      when there is not, rather than treated as distance-from-zero,
    ///      which would silently become "earliest in the document" and hide
    ///      the fact that we never located their attention at all.
    ///   4. EARLIEST in the document — stable, and matches how a person reads.
    ///   5. SHORTEST span — the more surgical of two overlapping picks.
    ///
    /// After 4 and 5, two survivors have the same lower bound and the same
    /// length: they are the same span, and which one "wins" cannot matter.
    public static func precedes(
        _ lhs: PassageCandidate, _ rhs: PassageCandidate, anchor: Int?
    ) -> Bool {
        if lhs.rung != rhs.rung { return lhs.rung < rhs.rung }
        if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
        if let anchor {
            let lhsDistance = distance(from: lhs.range, to: anchor)
            let rhsDistance = distance(from: rhs.range, to: anchor)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        }
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound < rhs.range.lowerBound
        }
        return lhs.range.count < rhs.range.count
    }

    /// 0 when the anchor is inside the span — a candidate the user is looking
    /// at is not "near", it is where they are.
    public static func distance(from range: Range<Int>, to anchor: Int) -> Int {
        if anchor < range.lowerBound { return range.lowerBound - anchor }
        if anchor >= range.upperBound { return anchor - range.upperBound + 1 }
        return 0
    }

    public static func confidence(
        winner: PassageCandidate, runnerUp: PassageCandidate?
    ) -> PassageConfidence {
        guard let runnerUp else { return .exact }
        return winner.overlap - runnerUp.overlap < decisiveMargin ? .contested : .chosen
    }

    // MARK: - Rungs

    public static func verbatimCandidates(_ target: String, in body: String) -> [PassageCandidate] {
        let characters = Array(body)
        return occurrences(of: target, in: body)
            .filter { standsAlone($0, in: characters, target: target) }
            .map { PassageCandidate(range: $0, kind: .phrase, rung: .verbatim) }
    }

    /// IS THIS HIT A WHOLE WORD, or the inside of a longer one?
    ///
    /// "Replace purpose with aim" against a document containing "purposeful"
    /// would otherwise produce "aimful" — a silent, surgical, completely wrong
    /// edit, which is the exact species of failure this whole file exists to
    /// make unreachable. Even the literal rung checks it.
    ///
    /// Checked only on an END THAT IS ITSELF ALPHANUMERIC: a target quoted
    /// with its own full stop, or one that starts mid-punctuation, has no word
    /// boundary to test there and must not be rejected for lacking one.
    public static func standsAlone(
        _ range: Range<Int>, in characters: [Character], target: String
    ) -> Bool {
        if let first = target.first, first.isLetter || first.isNumber, range.lowerBound > 0 {
            let before = characters[range.lowerBound - 1]
            if before.isLetter || before.isNumber { return false }
        }
        if let last = target.last, last.isLetter || last.isNumber,
           range.upperBound < characters.count {
            let after = characters[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    /// A span that IS a unit gets that unit's kind and label back.
    ///
    /// Rungs 0 and 2 search raw text and know nothing about structure, so a
    /// verbatim quote of an entire paragraph would otherwise come back as a
    /// `.phrase` — and `PassageEdit` would then insert around it with no blank
    /// lines, welding two paragraphs together. The structure was there; this
    /// is only refusing to throw it away.
    public static func named(_ candidates: [PassageCandidate], units: [PassageUnit]) -> [PassageCandidate] {
        guard !units.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard let unit = units.first(where: { $0.range == candidate.range }) else {
                return candidate
            }
            var refined = candidate
            refined.kind = unit.kind
            refined.label = unit.label
            return refined
        }
    }

    public static func structuralCandidates(
        _ target: String, units: [PassageUnit]
    ) -> [PassageCandidate] {
        guard !target.isEmpty else { return [] }
        let wanted = fold(target)
        guard !wanted.isEmpty else { return [] }
        // Exact label first. Containment is the fallback and never mixes with
        // it: "Purpose" matching the heading `Purpose` must not have to
        // compete with `Purpose and scope` on a tie-break.
        let exact = units.filter { fold($0.label) == wanted }
        let matched = exact.isEmpty
            ? units.filter { !$0.label.isEmpty && fold($0.label).contains(wanted) }
            : exact
        return matched.map {
            PassageCandidate(range: $0.range, label: $0.label, kind: $0.kind, rung: .structural)
        }
    }

    public static func overlapCandidates(
        _ target: String, in body: String, units: [PassageUnit]
    ) -> [PassageCandidate] {
        let wanted = AmbientRanker.tokens(target)
        guard !wanted.isEmpty else { return [] }
        var candidates: [PassageCandidate] = []
        for unit in units where unit.kind == .paragraph || unit.kind == .section {
            let have = AmbientRanker.tokens(substring(of: body, unit.range) + " " + unit.label)
            let overlap = Double(wanted.intersection(have).count) / Double(wanted.count)
            guard overlap >= minimumOverlap else { continue }
            candidates.append(PassageCandidate(
                range: unit.range, label: unit.label, overlap: overlap,
                kind: unit.kind, rung: .tokenOverlap))
        }
        return candidates
    }

    /// Their words were a fragment. Take the longest run of consecutive target
    /// words that is really in the body — strictly shorter than the whole
    /// target, because the whole target was rungs 0 and 2's job — and widen it
    /// to the smallest BLOCK unit that contains it.
    ///
    /// A `.phrase` unit is never a widening target: widening exists to make a
    /// replacement start where a paragraph starts, and widening a phrase to a
    /// phrase moves nothing. With no enclosing block unit at all the bare
    /// fragment stands as the candidate — a world with no structure reader can
    /// still be edited, it just cannot be widened.
    public static func widenedCandidates(
        _ target: String, folded: FoldedText, units: [PassageUnit]
    ) -> [PassageCandidate] {
        let words = target.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [] }
        let blocks = units.filter(\.kind.isBlock)
        for length in stride(from: words.count - 1, through: 1, by: -1) {
            var hits: [PassageCandidate] = []
            for start in 0...(words.count - length) {
                let fragment = words[start..<(start + length)].joined(separator: " ")
                // A fragment with no content word in it is grammar, not a
                // location: "of the" appears everywhere and locates nothing.
                guard !AmbientRanker.tokens(fragment).isEmpty else { continue }
                let overlap = Double(length) / Double(words.count)
                for hit in folded.candidates(for: fragment, rung: .widened) {
                    let enclosing = blocks
                        .filter { $0.contains(hit.range) }
                        .min { $0.length < $1.length }
                    hits.append(PassageCandidate(
                        range: enclosing?.range ?? hit.range,
                        label: enclosing?.label ?? "",
                        overlap: overlap,
                        kind: enclosing?.kind ?? .phrase,
                        rung: .widened,
                        narrower: hit.range))
                }
            }
            // ONE BLOCK IS ONE ANSWER, however many fragments reached it.
            // Every consecutive run of the target's words is tried against the
            // body, so a target with two disjoint fragments inside one
            // paragraph ("alpha beta … victor whiskey") nominates that
            // paragraph TWICE — identical range, identical overlap, differing
            // only in `narrower`. Two things break if both survive: the span
            // becomes its own runner-up, so `confidence` reads `.contested`
            // about a pick nothing competed with; and `narrower` is decided by
            // whichever way `sorted` happened to fall, because the duplicates
            // are inseparable under `precedes` and Swift's sort is not stable.
            // The block is the answer and the fragment is only the evidence
            // for it, so the EARLIEST fragment is kept — `start` ascends, so
            // that is simply the first one seen.
            if !hits.isEmpty {
                var seen: Set<Range<Int>> = []
                return hits.filter { seen.insert($0.range).inserted }
            }
        }
        return []
    }

    // MARK: - Target shaping

    /// THE LITERAL TARGET: surrounding whitespace and the quote marks a model
    /// wraps things in, and nothing else. Sentence punctuation SURVIVES here —
    /// stripping it is what turns a quoted whole paragraph into that paragraph
    /// minus its full stop, which then matches no unit and loses its structure.
    public static func trimTarget(_ target: String) -> String {
        target
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The literal target with the sentence mark a model tacked on the end
    /// removed — "the Purpose section." → "the Purpose section". Used by rungs
    /// 1 through 4, and by rung 0 only as its second pass.
    public static func cleanTarget(_ target: String) -> String {
        var text = trimTarget(target)
        while let last = text.last, last == "." || last == "?" || last == "!" || last == "," {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "the Purpose section" → "Purpose". Leading determiners off the front,
    /// then part-nouns off the back until only the NAME is left. Repeated
    /// because "the whole Purpose section heading" is a thing people say.
    public static func structuralTarget(_ target: String) -> String {
        var words = target.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first,
              leadingDeterminers.contains(fold(first)), words.count > 1 {
            words.removeFirst()
        }
        while let last = words.last, partNouns.contains(fold(last)), words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Case- and diacritic-insensitive, which is what "matching a heading"
    /// means when the heading is typed by a person and the target is spoken by
    /// one.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Offsets

    /// Every 0-based half-open occurrence of `needle` in `hay`.
    public static func occurrences(of needle: String, in hay: String) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        var found: [Range<Int>] = []
        var searchStart = hay.startIndex
        while let range = hay.range(of: needle, range: searchStart..<hay.endIndex) {
            let lower = hay.distance(from: hay.startIndex, to: range.lowerBound)
            let upper = hay.distance(from: hay.startIndex, to: range.upperBound)
            found.append(lower..<upper)
            searchStart = range.upperBound
        }
        return found
    }

    /// The characters at `range`, clamped. Clamped rather than trapped because
    /// a range that outran its body is exactly the stale-hint case the whole
    /// design assumes will happen, and crashing on it would be the loudest
    /// possible way to lose a document.
    public static func substring(of body: String, _ range: Range<Int>) -> String {
        let length = body.count
        let lower = max(0, min(range.lowerBound, length))
        let upper = max(lower, min(range.upperBound, length))
        guard lower < upper else { return "" }
        let start = body.index(body.startIndex, offsetBy: lower)
        let end = body.index(body.startIndex, offsetBy: upper)
        return String(body[start..<end])
    }

    // MARK: - Refusal

    public static func refusal(
        target: String, trace: [String], sentence: String? = nil
    ) -> PassageDecision {
        // The first sentence is `XcodeEditError.noMatch`'s, the second is
        // `PagesPlugin.targetedOutcome`'s. Both quoted rather than rewritten —
        // one phrasing for one fact, in a tree where the same miss has already
        // been narrated three different ways.
        let said = sentence
            ?? "I couldn't find \"\(String(cleanTarget(target).prefix(40)))\" to change. \(missReason)"
        return PassageDecision(
            span: nil, rung: nil, confidence: nil, runnerUp: nil,
            trace: trace, refusal: said, narrowerAlternative: nil,
            kind: nil, label: nil)
    }
}
