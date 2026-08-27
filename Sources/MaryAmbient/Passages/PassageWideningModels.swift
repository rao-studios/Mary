//
//  PassageWideningModels.swift
//  MaryAmbient
//
//  The value types PassageWidening.locate reads, decides among, and
//  returns. Split out of PassageWidening.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import Foundation

/// WHERE THE USER'S ATTENTION IS, expressed so it cannot be a lie.
///
/// TEXT-DERIVED, NEVER A RAW AX INTEGER. An AX offset counts UTF-16 code units
/// over a string that includes headers, footers and text boxes; a `body text`
/// offset counts characters over a string that excludes them. Feeding one into
/// the other is how the viewport once resolved to the head of the document on
/// every tick (`ViewportProvenance.diverged` is the detector for exactly this).
///
/// So there are two honest sources and no third: a selection range the CALLER
/// has already validated against this exact body, or the WORDS of the ambient
/// selection/viewport fact, which are located here by `range(of:)` in the body
/// itself. If those words are not in the body — the user is in a header, a
/// text box, a comment field — there is simply no anchor, the rung is skipped,
/// and the tie-break falls through to document order. Honest, not fudged.
public struct PassageAttention: Sendable, Equatable {

    /// A selection range the caller has already checked against THIS body.
    /// The caller owns that check because only the caller knows which string
    /// the offsets came out of.
    public var validatedSelection: Range<Int>?
    /// The ambient selection/viewport fact's own CONTENT — located by
    /// `range(of:)`, so a fact from a different coordinate space simply fails
    /// to locate instead of pointing somewhere arbitrary.
    public var text: String?

    public init(validatedSelection: Range<Int>? = nil, text: String? = nil) {
        self.validatedSelection = validatedSelection
        self.text = text
    }

    /// The one offset the tie-break measures distance from, or nil.
    public func anchor(in body: String) -> Int? {
        let length = body.count
        if let selection = validatedSelection,
           selection.lowerBound >= 0,
           selection.upperBound <= length,
           selection.lowerBound <= selection.upperBound {
            return selection.lowerBound
        }
        guard let text, !text.isEmpty,
              let found = body.range(of: text) else { return nil }
        return body.distance(from: body.startIndex, to: found.lowerBound)
    }
}

/// Which rung found it. `Int` raw values because the tie-break's first term is
/// "rung ascending" and that has to be an arithmetic fact, not a switch.
public enum PassageRung: Int, Sendable, Equatable, CaseIterable, Comparable {
    case verbatim = 0
    case structural = 1
    case normalized = 2
    case tokenOverlap = 3
    case widened = 4

    public static func < (lhs: PassageRung, rhs: PassageRung) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// For the trace and the debugger.
    public var label: String {
        switch self {
        case .verbatim:     return "verbatim"
        case .structural:   return "structural label"
        case .normalized:   return "normalized"
        case .tokenOverlap: return "token overlap"
        case .widened:      return "widened"
        }
    }

    /// How the pick reads in a spoken report: "the section headed Purpose",
    /// "the words you gave me". Prose, because the report may not speak
    /// offsets.
    public var locatorNote: String {
        switch self {
        case .verbatim:     return "the words you gave me, exactly as they appear"
        case .structural:   return "the part with that heading"
        case .normalized:   return "the words you gave me, allowing for spacing and punctuation"
        case .tokenOverlap: return "the part that matches most of what you said"
        case .widened:      return "the part around the words you gave me"
        }
    }
}

/// HOW SURE the pick is — what drives whether the report offers a way back.
public enum PassageConfidence: String, Sendable, Equatable, CaseIterable {
    /// One candidate. There was nothing else it could have been.
    case exact
    /// Several candidates, and this one beat the next by at least
    /// `PassageWidening.decisiveMargin`.
    case chosen
    /// Several candidates and the margin was thin. The pick still happens —
    /// "read wider, then decide alone" — but the report names the runner-up so
    /// an unattended wrong pick is one sentence away from being corrected.
    case contested
}

/// One thing the target might have meant.
public struct PassageCandidate: Sendable, Equatable {
    public var range: Range<Int>
    /// The unit's own label, or "" for a span that is not a unit.
    public var label: String
    /// Fraction of the target's content words this span accounts for. 1.0 on
    /// every rung that matched the target WHOLE — the rungs that either match
    /// or don't have nothing partial to report.
    public var overlap: Double
    public var kind: PassageUnitKind
    public var rung: PassageRung
    /// The span BEFORE widening, on rung 4 only. The `maxSpan` refusal names
    /// this, so "too much" is never a dead end.
    public var narrower: Range<Int>?

    public init(
        range: Range<Int>, label: String = "", overlap: Double = 1.0,
        kind: PassageUnitKind, rung: PassageRung, narrower: Range<Int>? = nil
    ) {
        self.range = range
        self.label = label
        self.overlap = overlap
        self.kind = kind
        self.rung = rung
        self.narrower = narrower
    }
}

/// What one `locate` produced. `span == nil` is a REFUSAL and `refusal` then
/// carries the sentence to say.
public struct PassageDecision: Sendable, Equatable {
    public var span: Range<Int>?
    public var rung: PassageRung?
    public var confidence: PassageConfidence?
    /// The next-best candidate, named so a wrong unattended pick is
    /// recoverable. Nil when there was only ever one.
    public var runnerUp: PassageCandidate?
    /// Which rungs ran and what each found, in order. The debugger's answer to
    /// "why did she pick that", and the tests' answer to "did rung 2 really
    /// stay out of it".
    public var trace: [String]
    /// Spoken. Non-nil exactly when `span` is nil.
    public var refusal: String?
    /// On a `maxSpan` refusal: the narrower span that WOULD have been
    /// accepted, so the refusal can name it.
    public var narrowerAlternative: Range<Int>?
    /// The winning candidate's kind and label, carried out for the passage
    /// that gets minted from this.
    public var kind: PassageUnitKind?
    public var label: String?

    public var isRefusal: Bool { span == nil }
}

/// The body, folded once: whitespace collapsed to single spaces, punctuation
/// dropped, case and diacritics folded — with a map back to the ORIGINAL
/// character offsets, because a match in a normalized string is worthless if
/// it cannot say where in the real document it happened.
///
/// Built once per `locate` and shared by rungs 2 and 4, so the two cannot
/// disagree about what "the same words" means.
public struct FoldedText {
    /// The folded characters.
    public let characters: [Character]
    /// `origin[i]` is the offset in the ORIGINAL body of `characters[i]`.
    public let origin: [Int]

    public init(_ body: String) {
        var characters: [Character] = []
        var origin: [Int] = []
        var offset = 0
        for character in body {
            defer { offset += 1 }
            if character.isWhitespace {
                // A run of any whitespace becomes one space, and never a
                // leading one: "\n\n  Purpose" and " Purpose" have to fold to
                // the same thing or a heading at the top of a document is
                // unfindable.
                if let last = characters.last, last != " " {
                    characters.append(" ")
                    origin.append(offset)
                }
                continue
            }
            if character.isPunctuation || character.isSymbol { continue }
            for folded in String(character)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
                characters.append(folded)
                origin.append(offset)
            }
        }
        self.characters = characters
        self.origin = origin
    }

    /// Candidates for `needle`, folded the same way, mapped back to original
    /// offsets.
    ///
    /// WORD-BOUNDARY CHECKED, unlike the verbatim rung. Punctuation is gone by
    /// this point, so without it "purpose" would match inside "purposeful" and
    /// a fuzzy rung would quietly out-locate an exact one.
    public func candidates(for needle: String, rung: PassageRung) -> [PassageCandidate] {
        let folded = FoldedText(needle).characters
        guard !folded.isEmpty, folded.count <= characters.count else { return [] }
        var candidates: [PassageCandidate] = []
        for start in 0...(characters.count - folded.count) {
            let end = start + folded.count
            guard characters[start..<end].elementsEqual(folded) else { continue }
            if start > 0, characters[start - 1] != " " { continue }
            if end < characters.count, characters[end] != " " { continue }
            candidates.append(PassageCandidate(
                range: origin[start]..<(origin[end - 1] + 1),
                kind: .phrase,
                rung: rung))
        }
        return candidates
    }
}
