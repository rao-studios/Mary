//
//  ProseWriteModels.swift
//  MaryPlugin
//
//  WHAT: Locate/replace math for a live AX text element (pure).
//  IN:   PagesPassageWriter split  OUT: ProseSurfaceWriter
//  PIN:  Re-locate in the string THIS element just returned.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One candidate text element, as the locator sees it: WHICH branch of `PagesAX`'s cascade
/// produced it, and the whole string that element itself handed back.
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

/// Pure, so the sentences are pinned by tests rather than discovered in production.
public enum ProseWriteRefusal: Sendable, Equatable {
    /// AX is not trusted — the setter would fail silently, which is the one
    /// outcome worse than refusing.
    case accessibilityBlocked
    /// The application answered nothing text-shaped.
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

    /// The refusal as `PassageWriter`'s own vocabulary. `.notFound` maps to `.passageGone`,
    /// which is exactly clause 2 of the implementer's contract ("anything less certain
    /// throws `.passageGone`.
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

    /// WHICH ELEMENT, AND WHERE IN IT. The rule, in the order it is applied, and each
    /// clause is load-bearing: 1.
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

    /// Tie-break by proximity. Occurrences are AX offsets; hint is AppleScript `body text`.
    /// PIN: never subtract the two spaces. Gap is PassageResolver.driftMargin.
    private static func tieBreak(
        _ occurrences: [Range<Int>], index: Int, hint: Range<Int>
    ) -> ProseWriteChoice {
        guard let winner = nearest(occurrences, hint: hint) else {
            return .refused(.ambiguous(count: occurrences.count))
        }
        return .chosen(ProseWriteTarget(
            index: index, range: winner, occurrences: occurrences.count))
    }

    /// Margin rule lives in ParagraphWritePlanner so every write route shares one copy.
    /// Nil when the runner-up is not clearly further — a refusal, not document-order fallback.
    static func nearest(_ occurrences: [Range<Int>], hint: Range<Int>) -> Range<Int>? {
        // This one rule survives because it is about AMBIGUITY, not paragraphs.
        guard occurrences.count > 1 else { return occurrences.first }
        let byDistance = occurrences.sorted {
            abs($0.lowerBound - hint.lowerBound) < abs($1.lowerBound - hint.lowerBound)
        }
        let closest = abs(byDistance[0].lowerBound - hint.lowerBound)
        let next = abs(byDistance[1].lowerBound - hint.lowerBound)
        guard next - closest >= PassageResolver.driftMargin else { return nil }
        return byDistance[0]
    }

    /// Character offsets → UTF-16 offsets, WITHIN A SINGLE STRING. Nil when the range does
    /// not fit the string, which is a caller bug rather than a document state, and is
    /// refused rather than clamped: a clamped write is a write to the wrong place. (An
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
