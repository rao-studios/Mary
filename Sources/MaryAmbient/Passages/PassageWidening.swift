//
//  PassageWidening.swift
//  MaryBrain
//
//  WHAT: Given what they called it, find the piece of the document they meant.
//  IN:   target, body, PassageUnit, attention
//  OUT:  PassageWideningModels decision. Never "which one did you mean?"
//  PIN:  Fixed ladder, stop at the first rung that yields. Pure — no I/O.
//

import Foundation

public enum PassageWidening {

    // MARK: - The constants, and the arithmetic behind each

    /// Rung 3 floor — fraction of the target's content words a unit must contain.
    /// PIN: Half, because spoken targets are short after stopwords drop.
    public static let minimumOverlap = 0.5

    /// Margin the winner needs for `.chosen` rather than `.contested` (quarter of target tokens).
    public static let decisiveMargin = 0.25

    /// Max widened span we will decide alone. Larger is refused and the narrower alternative named.
    public static let maxSpan = 4000

    /// Miss sentence — quoted from `PagesPlugin.targetedOutcome`. One phrasing for one fact.
    public static let missReason =
        "Headers, footers, text boxes and table cells live outside body text, "
        + "so it may be there and unreadable this way — or the wording differs."

    /// Words that name a part of a document rather than naming one. Stripped so "Purpose section" → "Purpose".
    public static let partNouns: Set<String> = [
        "section", "sections", "paragraph", "paragraphs", "para", "paras",
        "chapter", "chapters", "heading", "headings", "header", "part",
        "passage", "block", "bit", "clause", "sentence", "line", "lines",
        "function", "func", "method", "declaration", "decl",
    ]

    /// Leading determiners. Dropped so "the Purpose section" and "Purpose" reach the same place.
    public static let leadingDeterminers: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "its", "his", "her",
        "their", "whole", "entire",
    ]

    // MARK: - The ladder

    /// Find the piece of `body` that `target` names. Empty `units` is legal — rungs 1 and 3 drop out.
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

        // Rung 0 — user's own words, exactly. Literal first so a quoted sentence keeps its full stop.
        let literal = trimTarget(target)
        candidates = named(verbatimCandidates(literal, in: body), units: units)
        if candidates.isEmpty, wanted != literal {
            candidates = named(verbatimCandidates(wanted, in: body), units: units)
        }
        trace.append("rung 0 verbatim: \(candidates.count)")

        // Rung 1 — unit label. `structuralTarget` drops the trailing part-noun ("Purpose section" → "Purpose").
        if candidates.isEmpty {
            candidates = structuralCandidates(structural, units: units)
            trace.append("rung 1 structural (\"\(structural)\"): \(candidates.count)")
        }

        // Rung 2 — same words, folded. Word-boundary so "purpose" does not match inside "purposeful".
        if candidates.isEmpty {
            candidates = named(folded.candidates(for: wanted, rung: .normalized), units: units)
            trace.append("rung 2 normalized: \(candidates.count)")
        }

        // Rung 3 — token overlap. `AmbientRanker.tokens` is the one stopword list in this tree.
        if candidates.isEmpty {
            candidates = overlapCandidates(structural, in: body, units: units)
            trace.append("rung 3 token overlap (>= \(minimumOverlap)): \(candidates.count)")
        }

        // Rung 4 — their words were only a fragment of what is written.
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
        // Runner-up must be a different span.
        let runnerUp = ordered.dropFirst().first { $0.range != winner.range }
        let confidence = confidence(winner: winner, runnerUp: runnerUp)
        trace.append(
            "picked \(winner.range.lowerBound)..<\(winner.range.upperBound) "
            + "at rung \(winner.rung.rawValue) (\(winner.rung.label)), \(confidence.rawValue)")

        // Safety valve — only rung 4 can trip it. See `maxSpan`.
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

    /// Total order so `locate` never returns "ask the user".
    /// STEPS: rung asc → overlap desc → nearest attention (skip if no anchor)
    ///        → earliest in document → shortest span.
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

    /// 0 when the anchor is inside the span — they are looking at it, not near it.
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

    /// Whole-word hit, not the inside of a longer word ("purpose" vs "purposeful").
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

    /// If the span is a unit, attach that unit's kind and label (rungs 0 and 2 search raw text).
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
        // Exact label first. Containment is fallback and never mixes with it.
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

    /// Widened fragment — longest consecutive target-word run that is really in the body.
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
                // Fragment with no content word is grammar, not a location.
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
            // One block is one answer, however many fragments reached it.
            if !hits.isEmpty {
                var seen: Set<Range<Int>> = []
                return hits.filter { seen.insert($0.range).inserted }
            }
        }
        return []
    }

    // MARK: - Target shaping

    /// Literal target — surrounding whitespace and wrapping quote marks, nothing else.
    public static func trimTarget(_ target: String) -> String {
        target
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim plus trailing sentence mark. Rungs 1–4; rung 0 uses it as its second pass.
    public static func cleanTarget(_ target: String) -> String {
        var text = trimTarget(target)
        while let last = text.last, last == "." || last == "?" || last == "!" || last == "," {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "the Purpose section" → "Purpose". Strip leading determiners, then trailing part-nouns.
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

    /// Case- and diacritic-insensitive fold — spoken target vs typed heading.
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

    /// Characters at `range`, clamped. Stale hints outrun the body — do not trap.
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
        // Quoted from `XcodeEditError.noMatch` then `PagesPlugin.targetedOutcome` — one phrasing per fact.
        let said = sentence
            ?? "I couldn't find \"\(String(cleanTarget(target).prefix(40)))\" to change. \(missReason)"
        return PassageDecision(
            span: nil, rung: nil, confidence: nil, runnerUp: nil,
            trace: trace, refusal: said, narrowerAlternative: nil,
            kind: nil, label: nil)
    }
}
