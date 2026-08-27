//
//  PassageEdit.swift
//  MaryBrain
//
//  PURE TEXT MATH over a document body — the passage-shaped mirror of
//  `XcodeEdit`, and for the same reason it exists there: the arithmetic of an
//  edit is the part that can be tested to death, so it is kept where no app,
//  no AppleScript and no Accessibility call can reach it.
//
//  Each operation computes THREE things, and the third is the one this file
//  has that `XcodeEdit` does not:
//
//    - `newBody`     the whole document afterwards. What a WHOLE-BUFFER writer
//                    sends (Xcode's atomic disk write).
//    - `changedRange` where it landed. INFORMATIONAL ONLY — see below.
//    - `anchorText` / `replacement`
//                    the substring to FIND and what to put in its place. What
//                    a RANGED writer sends (the Pages AX select-and-set).
//
//  That last pair is the contract's load-bearing decision expressed as data: a
//  passage's identity is its TEXT, so even an insertion is spelled "find these
//  words, put these words there instead" rather than "write at offset 68". A
//  writer given only offsets is the writer that produced
//  `Can't get text from character 68 to character 916 of body text of
//  document 1. (-1728)`.
//

import Foundation

/// The four things a revision can be.
public enum PassageOperation: String, Sendable, Equatable, CaseIterable {
    case replace
    case insertBefore
    case insertAfter
    case delete
}

/// One computed edit. Nothing here has touched a document yet.
public struct PassageEditResult: Sendable, Equatable {
    /// The whole document afterwards.
    public var newBody: String
    /// Where the new text sits in `newBody`, 0-based half-open.
    ///
    /// INFORMATIONAL ONLY (tests, a future "around line N" narration) — NEVER
    /// SENT TO XCODE AS A SELECTION. `XcodeEdit.EditResult.newSelection` says
    /// it in its own words and the reason is the same one: Xcode's sdef
    /// selection setter asserts instead of clamping and crashes the whole IDE
    /// (see `XcodeScripting.modifiedStateScript`, fact 2 — that header is
    /// where the three live-verified facts about Xcode's scripting surface
    /// now live). No writer built on this file
    /// may send a computed selection to Xcode, and a field that looks like a
    /// selection has to say so where a writer will read it.
    public var changedRange: Range<Int>
    /// The body as it was. `ContentUndoStore.record(key:prior:applied:)` takes
    /// this, and `revert_last_edit` hands it back — hash-guarded, so it can
    /// never clobber work done since.
    public var priorBody: String
    /// A spoken CLAUSE, lowercase and unpunctuated, for a report to compose:
    /// "replaced the Purpose section". Never a whole sentence — the report
    /// owns the sentence, and two files each owning half of one is how the
    /// same edit came to be narrated three different ways.
    public var summaryClause: String
    /// The exact substring of `priorBody` a RANGED writer must find.
    public var anchorText: String
    /// What that writer puts in its place. `anchorText` → `replacement`
    /// produces `newBody` exactly.
    public var replacement: String
}

public extension PassageUnit {
    /// The unit a RE-ANCHORED passage stands for.
    ///
    /// The range is the resolver's answer, not the passage's stored hint —
    /// that substitution is the entire point of `PassageResolver`, and taking
    /// it as a parameter is how the type system asks for it.
    init(_ passage: Passage, at range: Range<Int>) {
        self.init(range: range, label: "", level: 0, kind: passage.unitKind)
    }
}

public enum PassageEdit {

    /// What separates one block from the next. Blocks only — a `.phrase` sits
    /// inside a sentence, and any separator we choose for it is a guess about
    /// grammar we have no business making. See `PassageUnitKind.isBlock`.
    public static let blockSeparator = "\n\n"

    /// ONE SPACE, OR NONE, at the seam an insert around a `.phrase` creates.
    ///
    /// THE WELD THIS PREVENTS: a phrase took `""` for its separator — the
    /// literal reading of "any separator we choose is a guess about grammar" —
    /// so `insertAfter` on the phrase `budget forecast` with the payload
    /// `summary` put `forecastsummary` into the user's sentence. That is not
    /// grammar we declined to guess at; it is two words run together, which is
    /// wrong in every grammar. A space between two non-space characters is the
    /// one thing about the seam that is not a judgement call.
    ///
    /// `left` and `right` are THE STRINGS THAT WILL TOUCH, in document order —
    /// which of them is the passage and which is the new wording depends on the
    /// operation, and getting that backwards is the whole failure, so the labels
    /// name the seam rather than the roles. `insertBefore` puts the payload on
    /// the left, `insertAfter` on the right.
    ///
    /// Nothing is added when either facing edge already carries whitespace: the
    /// caller who wrote `" summary"` meant that space, and a second one beside
    /// it is the same class of mistake in the other direction. `blockSeparator`
    /// is untouched by this — a block supplies its own blank lines and trims the
    /// payload to match.
    public static func phraseSeparator(left: String, right: String) -> String {
        guard let tail = left.last, let head = right.first else { return "" }
        return (tail.isWhitespace || head.isWhitespace) ? "" : " "
    }

    /// BELOW THIS SHARE of the passage, "replaced" overstates what happened.
    ///
    /// `PassageEditRunner` routes a `.replace` through `minimalChange`, so a
    /// recompose that weaves one sentence into a five-paragraph section writes
    /// that one sentence and leaves the rest of the section exactly as it was.
    /// "Done — I replaced the Background section" is then a bigger claim than
    /// the edit, and the user hears it as their section having been rewritten.
    ///
    /// ONE THIRD, and the arithmetic is the two shapes it has to separate: a
    /// thought worked into a section is a few per cent of it, and a genuine
    /// rewrite that happens to leave the opening and the closing sentence
    /// standing is still most of it. Anything between reads acceptably either
    /// way, which is why the boundary can be a round fraction rather than a
    /// measurement.
    public static let wovenFraction = 1.0 / 3.0

    /// Compute an edit. Nothing is written.
    ///
    /// `unit` carries the range AND the kind, because the separators depend on
    /// the kind and a signature that took a bare range would let a caller
    /// weld two paragraphs together by forgetting an argument.
    public static func apply(
        _ operation: PassageOperation,
        text: String,
        to unit: PassageUnit,
        in body: String
    ) -> PassageEditResult {
        let characters = Array(body)
        let length = characters.count
        let lower = max(0, min(unit.range.lowerBound, length))
        let upper = max(lower, min(unit.range.upperBound, length))
        let existing = String(characters[lower..<upper])
        // Trim only for BLOCK kinds. A block's own blank lines are supplied
        // here, so leading/trailing newlines in the payload would double them;
        // a phrase's payload is placed bare, and trimming it would silently
        // eat spacing the caller meant.
        let payload = unit.kind.isBlock
            ? text.trimmingCharacters(in: .newlines)
            : text

        var anchorLower = lower
        var anchorUpper = upper
        var replacement: String
        var changedLower: Int
        var changedLength: Int

        switch operation {
        case .replace:
            replacement = payload
            changedLower = lower
            changedLength = payload.count

        case .insertBefore:
            // The seam is payload|existing — the payload lands in FRONT, so it
            // is the payload's LAST character and the passage's FIRST that end
            // up touching. See `phraseSeparator`.
            let seam = unit.kind.isBlock
                ? blockSeparator
                : phraseSeparator(left: payload, right: existing)
            replacement = payload + seam + existing
            changedLower = lower
            changedLength = payload.count

        case .insertAfter:
            // And here the seam is existing|payload — the other pair of edges.
            let seam = unit.kind.isBlock
                ? blockSeparator
                : phraseSeparator(left: existing, right: payload)
            replacement = existing + seam + payload
            changedLower = lower + existing.count + seam.count
            changedLength = payload.count

        case .delete:
            // COLLAPSE THE HOLE. Removing a block from between two blank-line
            // separators leaves four newlines where two belong, so the anchor
            // deliberately reaches OUT past the passage to swallow them and
            // put back exactly the separator the document should have.
            //
            // Unconditional, and safe for a phrase: a mid-sentence seam has no
            // newlines around it, so both counts are zero and this does
            // nothing. One branch fewer is one branch that cannot be wrong.
            var before = 0
            while anchorLower - 1 >= 0, characters[anchorLower - 1].isNewline {
                anchorLower -= 1
                before += 1
            }
            var after = 0
            while anchorUpper < length, characters[anchorUpper].isNewline {
                anchorUpper += 1
                after += 1
            }
            // At the very top or the very bottom of the document there is
            // nothing on one side to separate from, so the separator goes too
            // — otherwise deleting the first paragraph leaves the document
            // starting with a blank line.
            let atStart = anchorLower == 0
            let atEnd = anchorUpper == length
            let surviving = (atStart || atEnd) ? 0 : min(before + after, 2)
            replacement = String(repeating: "\n", count: surviving)
            changedLower = anchorLower + surviving
            changedLength = 0
        }

        let anchorText = String(characters[anchorLower..<anchorUpper])
        let newBody = String(characters[0..<anchorLower])
            + replacement
            + String(characters[anchorUpper..<length])

        return PassageEditResult(
            newBody: newBody,
            changedRange: changedLower..<(changedLower + changedLength),
            priorBody: body,
            summaryClause: summaryClause(operation, unit: unit),
            anchorText: anchorText,
            replacement: replacement)
    }

    /// How the change reads out loud. Deterministic and built here rather than
    /// by the model — `EditReport`'s rule, applied to its smallest piece.
    ///
    /// `changedFraction` IS THE FACT, NOT A SECOND SENTENCE-BUILDER. The
    /// runner is the only thing that knows how much of the passage the writer
    /// was actually handed (it is what ran `minimalChange`), so it supplies the
    /// number and the clause is still chosen here — one place where an
    /// operation becomes words, which is what stopped the same edit being
    /// narrated three different ways. It defaults to the whole passage, so
    /// `apply` and every caller that never narrowed anything reads exactly as
    /// it did before.
    public static func summaryClause(
        _ operation: PassageOperation, unit: PassageUnit, changedFraction: Double = 1
    ) -> String {
        let subject = spokenSubject(unit)
        switch operation {
        case .replace:
            // A recompose that moved one sentence inside a section did not
            // replace the section, and saying so makes the user reach for undo.
            return changedFraction < wovenFraction
                ? "worked that into \(subject)"
                : "replaced \(subject)"
        case .insertBefore: return "put that in before \(subject)"
        case .insertAfter:  return "added that after \(subject)"
        case .delete:       return "took out \(subject)"
        }
    }

    /// What to CALL the thing that changed. A named declaration speaks as its
    /// own name ("replaced resolveFocus"); everything else takes its kind's
    /// noun, with the label in front when there is one.
    public static func spokenSubject(_ unit: PassageUnit) -> String {
        let label = unit.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch unit.kind {
        case .declaration:
            return label.isEmpty ? "that declaration" : label
        case .section, .paragraph:
            return label.isEmpty
                ? "that \(unit.kind.spokenNoun)"
                : "the \(label) \(unit.kind.spokenNoun)"
        case .phrase, .window:
            return "that \(unit.kind.spokenNoun)"
        }
    }
}
