//
//  PagesPassageWriterModels.swift
//  MaryBrain
//
//  Split out of PagesPassageWriter.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One candidate text element, as the locator sees it: WHICH branch of
/// `PagesAX`'s cascade produced it, and the whole string that element itself
/// handed back.
///
/// The element is deliberately absent. A decision that could reach an
/// `AXUIElement` is a decision no test can run, and every decision on this path
/// is one a test must be able to run.
public struct ProseTextCandidate: Sendable, Equatable {
    public init(resolution: PerceptionElementResolution, text: String) {
        self.resolution = resolution
        self.text = text
    }

    public var resolution: PerceptionElementResolution
    /// The element's OWN string — whatever `AXStringForRange` (or
    /// `kAXValue`) returned for it. Never a body read from somewhere else:
    /// re-locating in a string a different API produced is the bug.
    public var text: String
}

/// Where to write, in Character offsets into the CHOSEN candidate's own string.
public struct ProseWriteTarget: Sendable, Equatable {
    /// Index into the candidate array handed to `choose`.
    public var index: Int
    /// 0-based half-open CHARACTER offsets into `candidates[index].text`.
    /// Converted to UTF-16 exactly once, locally, by `utf16Range`.
    public var range: Range<Int>
    /// How many times the passage appeared in that candidate. 1 on the happy
    /// path; >1 means the hint broke a tie, which the report should say out
    /// loud rather than quietly claim certainty about.
    public var occurrences: Int
}

/// WHY A WRITE DID NOT HAPPEN. Pure, so the sentences are pinned by tests
/// rather than discovered in production.
///
/// Every one of these is a case where the user asked for a CHANGE and the
/// change did not happen — so every one rides `ok: false` and gets SPOKEN
/// (`PassageResolver.refusal`'s doctrine: `foundNothing` is for a READ that
/// looked and did not find, and dressing an unmade edit as one would report it
/// as an answer, in silence).
public enum ProseWriteRefusal: Sendable, Equatable {
    /// AX is not trusted — the setter would fail silently, which is the one
    /// outcome worse than refusing.
    case accessibilityBlocked
    /// the application answered nothing text-shaped at all.
    case noTextElement
    /// No candidate's string contains the passage. The ghost-window case ends
    /// here too, and correctly: whatever the application is showing, it is not this text.
    case notFound
    /// More than one occurrence and the hint could not separate them by a clear
    /// enough margin. Refused rather than guessed — the thing being refused is
    /// overwriting the wrong paragraph.
    case ambiguous(count: Int)
    /// `kAXSelectedTextRange` would not take the range. Nothing was written.
    case selectionRefused(code: Int)
    /// The locate phase did not come back inside its budget — a beachballing
    /// the application, an autosave of a very large document.
    case timedOut(seconds: TimeInterval)

    /// The refusal as `PassageWriter`'s own vocabulary.
    ///
    /// `.notFound` maps to `.passageGone`, which is exactly clause 2 of the
    /// implementer's contract ("anything less certain throws `.passageGone` —
    /// containment IS the validation").
    ///
    /// KNOWN ROUGH EDGE, named rather than hidden: `.ambiguous` has no home of
    /// its own in `PassageWriteError`, so it rides `.axRefused`, whose sentence
    /// opens "I found it, and the app wouldn't let me set the text —". That
    /// opening is not quite true of an ambiguity (we found it several times and
    /// declined to choose). `PassageWriteError` wants a case for it; until it
    /// has one the DETAIL below carries the whole meaning, and it is pinned by
    /// a test so a later edit cannot quietly soften it into a guess.
    func writeError(opening: String, document: String) -> PassageWriteError {
        switch self {
        case .accessibilityBlocked:
            return .axRefused(detail:
                "Accessibility isn't granted, so I can't reach the words on the page. "
                + "Open my Settings and grant Accessibility under Permissions, and I'll make the change.")
        case .noTextElement:
            return .axRefused(detail:
                "the application isn't showing me any text I can work with. Click into the document "
                + "and ask me again.")
        case .notFound:
            return .passageGone(opening: opening, document: document)
        case .ambiguous(let count):
            return .axRefused(detail:
                "those exact words appear \(count) times in what the application hands me — its "
                + "headers and text boxes are in there too — so I won't guess which one you "
                + "meant. Name the heading above it and I'll change the right one.")
        case .selectionRefused(let code):
            return .axRefused(detail:
                "the application wouldn't let me select the passage (Accessibility error \(code)). "
                + "Click into the document and ask me again.")
        case .timedOut(let seconds):
            return .axRefused(detail:
                "the application didn't answer within \(Int(seconds)) seconds — it may be busy saving. "
                + "Give it a moment and ask me again.")
        }
    }
}

/// What `choose` decided.
public enum ProseWriteChoice: Sendable, Equatable {
    case chosen(ProseWriteTarget)
    case refused(ProseWriteRefusal)
}

/// THE DECISIONS, with no `AXUIElement` anywhere in sight.
public enum ProseWriteLocator {

    /// WHICH ELEMENT, AND WHERE IN IT.
    ///
    /// The rule, in the order it is applied, and each clause is load-bearing:
    ///
    ///   1. The first candidate whose string contains the passage EXACTLY ONCE
    ///      wins outright. One occurrence needs no tie-break, no hint and no
    ///      judgement — it is the certainty the whole contract is built on, and
    ///      it is checked across ALL candidates before any ambiguous one is
    ///      considered, so a header element that happens to repeat the words
    ///      can never outrank the body that has them once.
    ///   2. Only then, the first candidate with SEVERAL occurrences, decided by
    ///      the hint — and refused if the hint cannot decide.
    ///   3. Otherwise the passage is not in anything the application is showing.
    ///
    /// `hint` is used for exactly one thing here, and the signature is the only
    /// place it could be misused: picking between two IDENTICAL runs of text.
    /// It is never an address, and it is never converted.
    public static func choose(
        among candidates: [ProseTextCandidate],
        passageText: String,
        hint: Range<Int>
    ) -> ProseWriteChoice {
        guard !candidates.isEmpty else { return .refused(.noTextElement) }
        // An empty passage matches everywhere and therefore nowhere. Refusing
        // it as "not found" rather than trapping keeps a malformed edit a
        // spoken refusal instead of a crash in front of the user.
        guard !passageText.isEmpty else { return .refused(.notFound) }

        let hits = candidates.map { PassageWidening.occurrences(of: passageText, in: $0.text) }

        if let index = hits.firstIndex(where: { $0.count == 1 }) {
            return .chosen(ProseWriteTarget(
                index: index, range: hits[index][0], occurrences: 1))
        }
        if let index = hits.firstIndex(where: { $0.count > 1 }) {
            return tieBreak(hits[index], index: index, hint: hint)
        }
        return .refused(.notFound)
    }

    /// THE TIE-BREAK, and why proximity is allowed to decide it at all.
    ///
    /// The occurrences are offsets into ACCESSIBILITY's string; the hint is an
    /// offset into APPLESCRIPT's `body text`. Those are different spaces and
    /// this function does not pretend otherwise — it never subtracts one from
    /// the other to get a position. What it uses is that the two spaces differ
    /// by a PREFIX (the header/footer/text-box runs AX includes and `body text`
    /// omits), so an occurrence that is far nearer the hint than the runner-up
    /// is far nearer in both spaces.
    ///
    /// "Far nearer" is `PassageResolver.driftMargin` — the tree's existing
    /// spelling of "proximity is only evidence past this gap", and deliberately
    /// not a second number invented here. Below it, two identical passages are
    /// a coin toss, and the thing a coin toss decides is which of the user's
    /// paragraphs gets overwritten.
    ///
    /// REJECTED ALTERNATIVE, recorded because it looks better than it is:
    /// matching by ORDINAL (the hint says the 2nd occurrence in the body, so
    /// take the 2nd in AX). It assumes AX lists the body's occurrences in the
    /// body's order with nothing interleaved — but a header run can sort BEFORE
    /// the body, which silently shifts every ordinal by one and gives a
    /// confident, wrong answer. Distance degrades to a refusal; the ordinal
    /// degrades to a wrong write.
    private static func tieBreak(
        _ occurrences: [Range<Int>], index: Int, hint: Range<Int>
    ) -> ProseWriteChoice {
        guard let winner = nearest(occurrences, hint: hint) else {
            return .refused(.ambiguous(count: occurrences.count))
        }
        return .chosen(ProseWriteTarget(
            index: index, range: winner, occurrences: occurrences.count))
    }

    /// THE MARGIN RULE ITSELF, and it now lives in `ParagraphWritePlanner` so
    /// that EVERY write route in the tree obeys one copy of it — not merely
    /// the application' two.
    ///
    /// The planner calls it over the AppleScript body and `tieBreak` above
    /// calls it over an Accessibility element's string, and the property that
    /// matters shows up only on the fallback path: when the AppleScript route
    /// declines and the Accessibility chain runs on the same edit, both must
    /// choose the SAME occurrence. Two implementations of "near enough to be
    /// evidence" would drift apart eventually, and what the drift would produce
    /// is a write to the paragraph the user did not name. A third world writing
    /// paragraphs is exactly when that argument stops being about one file.
    ///
    /// Nil when the runner-up is not clearly further — which is a refusal, not
    /// a fallback to document order.
    static func nearest(_ occurrences: [Range<Int>], hint: Range<Int>) -> Range<Int>? {
        // Inlined from Bonnie's paragraph planner, which Mary does not carry:
        // its arithmetic served `paragraph N` writes, and the prose surface
        // substitutes located text ranges instead. This one rule survives
        // because it is about AMBIGUITY, not paragraphs.
        guard occurrences.count > 1 else { return occurrences.first }
        let byDistance = occurrences.sorted {
            abs($0.lowerBound - hint.lowerBound) < abs($1.lowerBound - hint.lowerBound)
        }
        let closest = abs(byDistance[0].lowerBound - hint.lowerBound)
        let next = abs(byDistance[1].lowerBound - hint.lowerBound)
        guard next - closest >= PassageResolver.driftMargin else { return nil }
        return byDistance[0]
    }

    /// THE ONE CONVERSION THIS DESIGN PERMITS: Character offsets → UTF-16
    /// offsets, WITHIN A SINGLE STRING.
    ///
    /// It is safe for the reason no other conversion in this area is: both
    /// sides describe the same string, so there is nothing to be wrong about
    /// except counting — and counting is what `String` does correctly and a
    /// hand-written offset arithmetic does not. A CRLF pair is one Character
    /// and two UTF-16 units; an emoji is one Character and two or more; a
    /// flag is one Character and four. Every one of those is a silent
    /// off-by-N in an Accessibility range, and an Accessibility range that is
    /// off by N selects — and then replaces — N characters of somebody's
    /// sentence.
    ///
    /// Nil when the range does not fit the string, which is a caller bug
    /// rather than a document state, and is refused rather than clamped: a
    /// clamped write is a write to the wrong place. (An INVERTED range needs no
    /// guard — `Range` traps on construction, so `4..<2` never reaches here.)
    static func utf16Range(of characters: Range<Int>, in text: String) -> Range<Int>? {
        guard characters.lowerBound >= 0, characters.upperBound <= text.count
        else { return nil }
        let lower = text.index(text.startIndex, offsetBy: characters.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: characters.upperBound)
        let units = text.utf16
        return units.distance(from: units.startIndex, to: lower)
            ..< units.distance(from: units.startIndex, to: upper)
    }
}
