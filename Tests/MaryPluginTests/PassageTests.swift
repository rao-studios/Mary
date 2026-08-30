//
//  PassageTests.swift
//  MaryPluginTests
//
//  WHAT: Passage locate / re-anchor / replace for whole-block edits.
//  OUT:  PassageWidening + PassageResolver + PassageEdit
//  PIN:  "Purpose section" is a heading match; gone beats the text that moved into its place
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryAmbient

// MARK: - Fixtures

/// The document from the incident, near enough to speak about.
private let purposeDoc = """
DeepFake Accountability

Purpose

This document sets out the rules for synthetic media disclosure before the next review.

Scope

Everything published under the imprint, including drafts.
"""

/// Offsets of a literal, computed rather than hand-counted — a test that
/// hard-codes 68 and 916 is a test that reproduces the bug.
private func at(_ needle: String, in body: String = purposeDoc) -> Range<Int> {
    guard let found = body.range(of: needle) else {
        Issue.record("fixture does not contain \"\(needle)\"")
        return 0..<0
    }
    return body.distance(from: body.startIndex, to: found.lowerBound)
        ..< body.distance(from: body.startIndex, to: found.upperBound)
}

private let purposeSection = at("""
Purpose

This document sets out the rules for synthetic media disclosure before the next review.
""")

private let scopeSection = at("""
Scope

Everything published under the imprint, including drafts.
""")

private let purposeParagraph =
    at("This document sets out the rules for synthetic media disclosure before the next review.")
private let scopeParagraph =
    at("Everything published under the imprint, including drafts.")

/// Headings and their bodies — what a `PagesStructure` will hand over.
private let purposeUnits: [PassageUnit] = [
    PassageUnit(range: at("DeepFake Accountability"), label: "DeepFake Accountability",
                level: 1, kind: .section),
    PassageUnit(range: purposeSection, label: "Purpose", level: 1, kind: .section),
    PassageUnit(range: purposeParagraph, kind: .paragraph),
    PassageUnit(range: scopeSection, label: "Scope", level: 1, kind: .section),
    PassageUnit(range: scopeParagraph, kind: .paragraph),
]

/// Paragraphs only — the shape a world with no heading structure produces.
private let purposeParagraphsOnly: [PassageUnit] = [
    PassageUnit(range: purposeParagraph, kind: .paragraph),
    PassageUnit(range: scopeParagraph, kind: .paragraph),
]

// MARK: - The ladder

@Suite struct PassageWideningLadderTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    /// THE INCIDENT. "Purpose section" is not in the document — the word
    /// "section" never appears — so this can only work if rung 1 strips the
    /// trailing part-noun and matches the HEADING. One candidate, so there was
    /// nothing else it could have been: `.exact`.
    @Test(arguments: [
        "Purpose section", "the Purpose section", "purpose SECTION", "the Purpose section.",
    ])
    func theLiveCaseResolvesToTheSectionHeadedPurpose(target: String) {
        let decision = PassageWidening.locate(
            target: target, in: purposeDoc, units: purposeUnits)
        #expect(decision.span == purposeSection)
        #expect(decision.rung == .structural)
        #expect(decision.confidence == .exact)
        #expect(decision.runnerUp == nil)
        #expect(decision.label == "Purpose")
        #expect(decision.kind == .section)
        #expect(decision.refusal == nil)
    }

    /// Rung 0. Their own words, exactly, beat everything below.
    @Test func verbatimRungTakesTheUsersOwnWords() {
        let target = "the rules for synthetic media disclosure"
        let decision = PassageWidening.locate(
            target: target, in: purposeDoc, units: purposeUnits)
        #expect(decision.rung == .verbatim)
        #expect(decision.span == at(target))
        #expect(decision.confidence == .exact)
    }

    /// A verbatim quote of a WHOLE paragraph comes back as that paragraph, not
    /// as a loose phrase — otherwise an edit around it would weld two
    /// paragraphs together for want of a blank line.

    /// Rung 2. Spacing, punctuation, case and diacritics forgiven — and only
    /// reached because rungs 0 and 1 genuinely missed.

    /// NO RUNG MATCHES THE INSIDE OF A LONGER WORD — not even the literal one.
    /// "Replace purpose with aim" against a document containing "purposeful"
    /// would otherwise produce "aimful": a silent, surgical, completely wrong
    /// edit.
    @Test func noRungMatchesInsideALongerWord() {
        let decision = PassageWidening.locate(
            target: "purpose", in: "The purposeful redesign shipped.", units: [])
        #expect(decision.isRefusal)
    }

    /// A bare noun with no part-noun after it is taken LITERALLY. "Purpose
    /// section" means the section; "Purpose" means the word, and replacing a
    /// heading with a better heading is a real thing to ask for.

    /// Rung 3. Token overlap over paragraphs, using `AmbientRanker.tokens` —
    /// the one stopword list in this tree.

    /// THE FLOOR, in its own arithmetic. One of four words is 0.25 and does
    /// not qualify — a single incidental word must not carry a match. Three of
    /// three is 1.0 and does.

    /// AND WHAT HAPPENS INSTEAD IS THE USER'S RULE. Rung 3 declining is not a
    /// refusal — it falls through to rung 4, which locates the one word that
    /// IS there and widens to the block around it. "Read wider, then decide
    /// alone."

    /// Rung 4. Their words were a FRAGMENT of what is written; the fragment is
    /// found and then widened to the block that contains it, which begins
    /// where a block begins rather than mid-sentence.

    /// THE SAFETY VALVE ON DECIDING ALONE. A span WE widened to, above
    /// `maxSpan`, is refused — and the refusal names the narrower alternative
    /// so "too much" is never a dead end.
    @Test func maxSpanRefusesAWidenedPickAndNamesTheNarrowerOne() {
        let filler = String(repeating: "padding words here. ", count: 260)   // 5200 chars
        let body = filler + "budget forecast lives here. " + filler
        let whole = 0..<body.count
        #expect(whole.count > PassageWidening.maxSpan)
        let decision = PassageWidening.locate(
            target: "budget forecast summary",
            in: body,
            units: [PassageUnit(range: whole, kind: .window)])
        #expect(decision.isRefusal)
        #expect(decision.narrowerAlternative == at("budget forecast", in: body))
        #expect(decision.refusal?.contains("more than I'll change") == true)
    }

    /// A span the USER named is theirs, however long. The cap is on OUR
    /// widening, and rung 1 is not widening.

    /// Nothing on any rung. The refusal is quoted from this tree, not written
    /// fresh: `XcodeEditError.noMatch`'s opening and
    /// `PagesPlugin.targetedOutcome`'s reasons, word for word. One phrasing
    /// for one fact.

    /// The ladder STOPS. A rung-0 hit must not have to out-compete rung 3's
    /// fuzzy opinion about the same sentence.

    /// The part-nouns come off the back, the determiners off the front, and
    /// the NAME survives — including when the name is itself a noun that
    /// looks structural.
}

// MARK: - The tie-break

// MARK: - Confidence

// MARK: - Staleness

@Suite struct PassageResolverTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private func passage(
        text: String, range: Range<Int>, body: String, title: String = "Draft"
    ) -> Passage {
        Passage(
            handle: "S1", place: .application("quill"), documentKey: "/tmp/draft.pages",
            documentTitle: title, text: text,
            bodyHash: ContentUndoStore.hash(body), bodyLength: body.count,
            range: range, unitKind: .paragraph, provenance: .recipeRead)!
    }

    /// The hash matches, so the body is byte-for-byte what the range was
    /// measured against and there is nothing a search could add.
    @Test func exactWhenTheBodyHasNotMoved() {
        let body = "Alpha one.\n\nBravo two."
        let held = passage(text: "Bravo two.", range: at("Bravo two.", in: body), body: body)
        #expect(PassageResolver.anchor(held, in: body) == .exact)
        #expect(PassageResolver.refusal(.exact, for: held) == nil)
    }

    /// THE COMMON CASE, and the reason the stored range is only a hint: she
    /// edited what came before, every offset below it moved, and the passage
    /// is still perfectly findable by its words.
    @Test func reanchoredAfterEverythingAboveItMoved() {
        let body = "Alpha one.\n\nBravo two."
        let held = passage(text: "Bravo two.", range: at("Bravo two.", in: body), body: body)
        let after = "Alpha one, considerably expanded.\n\nBravo two."
        let outcome = PassageResolver.anchor(held, in: after)
        #expect(outcome == .reanchored(at("Bravo two.", in: after), drift: 23))
        #expect(outcome.isResolved)
        #expect(PassageResolver.refusal(outcome, for: held) == nil)
    }

    /// THE HEADLINE REFUSAL. The passage is gone and a DIFFERENT paragraph now
    /// sits at exactly the offsets it used to occupy. Anything that trusted
    /// the stored range would overwrite text the user never named, silently.
    /// It must be `.gone`.
    @Test func goneRatherThanTheTextThatMovedIntoItsPlace() {
        let body = "Alpha one.\n\nBravo two."
        let held = passage(text: "Bravo two.", range: at("Bravo two.", in: body), body: body)
        let after = "Alpha one.\n\nDelta six."
        let outcome = PassageResolver.anchor(held, in: after)
        #expect(outcome == .gone)
        #expect(!outcome.isResolved)
        #expect(PassageResolver.range(outcome, of: held) == nil)
        // `ok: false` at the recipe, spoken — not `foundNothing`. The user
        // asked for a CHANGE and it did not happen.
        let spoken = PassageResolver.refusal(outcome, for: held)
        #expect(spoken?.contains("Bravo two.") == true)
        #expect(spoken?.contains("Draft") == true)
    }

    /// Two copies, both plausible, neither far enough from the old position to
    /// be evidence. Refused rather than guessed.

    /// Far enough apart to be evidence: one occurrence is more than a maximal
    /// edit's worth of movement closer than the other.

    /// The margin is the widening cap, read from there rather than repeated.
}

// MARK: - The edit math

@Suite struct PassageEditTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private let body = "Alpha one.\n\nBravo two.\n\nCharlie three."
    private var bravo: PassageUnit {
        PassageUnit(range: at("Bravo two.", in: body), label: "Bravo", kind: .paragraph)
    }

    @Test func replaceSwapsTheBlockAndLeavesItsSeparators() {
        let result = PassageEdit.apply(.replace, text: "Delta four.", to: bravo, in: body)
        #expect(result.newBody == "Alpha one.\n\nDelta four.\n\nCharlie three.")
        #expect(result.summaryClause == "replaced the Bravo paragraph")
    }

    @Test func insertBeforeAndAfterSupplyTheBlankLine() {
        let before = PassageEdit.apply(.insertBefore, text: "Delta four.", to: bravo, in: body)
        #expect(before.newBody == "Alpha one.\n\nDelta four.\n\nBravo two.\n\nCharlie three.")
        let after = PassageEdit.apply(.insertAfter, text: "Delta four.", to: bravo, in: body)
        #expect(after.newBody == "Alpha one.\n\nBravo two.\n\nDelta four.\n\nCharlie three.")
    }

    /// Removing a block from between two separators leaves four newlines where
    /// two belong.
    @Test func deleteCollapsesTheBlankLineItLeavesBehind() {
        let result = PassageEdit.apply(.delete, text: "", to: bravo, in: body)
        #expect(result.newBody == "Alpha one.\n\nCharlie three.")
        #expect(result.anchorText == "\n\nBravo two.\n\n")
        #expect(result.replacement == "\n\n")
    }

    /// At the top or the bottom there is nothing on one side to separate from,
    /// so the separator goes too — otherwise deleting the first paragraph
    /// leaves the document starting on a blank line.

    /// A phrase sits inside a sentence and gets no blank lines — but it does
    /// get the ONE thing about the seam that is not a guess about grammar.
    ///
    /// THIS TEST WAS COMPENSATING FOR THE BUG IT WAS MEANT TO PIN. It passed
    /// `" summary"`, with a hand-supplied leading space, and asserted the result
    /// read correctly — so the assertion held while `insertAfter` on a `.phrase`
    /// was concatenating with `""` and welding `forecastsummary` into anything a
    /// caller wrote naturally. The payload here is now `"summary"`, exactly what
    /// a model composing a phrase would send, and the space has to come from
    /// `PassageEdit.phraseSeparator`.

    /// The seam rule alone, both edges, in the order they touch.
    ///
    /// `left` and `right` NAME THE SEAM RATHER THAN THE ROLES, because which of
    /// them is the passage and which is the new wording flips between
    /// `insertBefore` and `insertAfter` — and getting that backwards is the
    /// whole failure rather than a detail of it.

    /// THE REPORT VERB FOLLOWS THE REDUCTION, and this is the sentence the user
    /// would otherwise reach for undo over.
    ///
    /// `.replace` now goes through `minimalChange`, so "here is the Background
    /// section again, one sentence different" writes that one sentence and
    /// leaves the other five paragraphs exactly as they were. "Done — I replaced
    /// the Background section" is then a bigger claim than the edit; the user
    /// hears their section as having been rewritten, and goes looking.

    /// THE DEFAULT IS THE WHOLE PASSAGE, so every caller that never narrowed
    /// anything — `apply` itself, and the three operations that pass straight
    /// through `writeSpan` — reads exactly as it did before the ratio existed.

    /// The runner's half of the same fact. A widened anchor can legitimately be
    /// LONGER than the passage — `uniqueAnchor` grows outward past its edges —
    /// and 1 is what that means: as much as the whole thing.

    /// `priorBody` is what `ContentUndoStore.record` keeps and
    /// `revert_last_edit` hands back. It has to round-trip exactly.

    /// THE RANGED WRITER'S HALF. `anchorText` → `replacement` must reproduce
    /// `newBody` exactly, because that substitution — words in, words out — is
    /// the only thing a writer in a foreign coordinate space is ever handed.

    /// `changedRange` is informational and must still be right, or the
    /// debugger line it feeds is a lie.

    /// An out-of-date range is the case this whole design assumes will happen.
    /// Clamped, never trapped — crashing on it would be the loudest possible
    /// way to lose a document.
}

// MARK: - The registry

// MARK: - The one coordinate space

// MARK: - The refusals

/// THE ERRAND VOCABULARY, and it is deliberately a CLOSED LIST OF FETCH-SHAPED
/// PHRASES rather than "any imperative".
///
/// The failure being closed is specific and it is traced: a tool-using model
/// reads an imperative in a tool RESULT as an instruction it can carry out, and
/// the live transcript shows `OPEN_IN_PAGES` firing off the back of a passage
/// refusal that never mentions Pages — nothing anywhere in the passage path
/// calls it. So the phrases that matter are the ones a tool could actually
/// obey: go and get the document, put it in front of me, bring it up.
///
/// TWO THINGS ARE DELIBERATELY NOT IN HERE, and saying so is the difference
/// between a pin and a lint rule:
///
///   - BARE "open". "a document open in Pages" is a DESCRIPTION of a state, and
///     `PassageEditRunner.noDocumentMessage` and `PassageRecipes.noWorldMessage`
///     both say exactly that. Only "open the document"/"open it"/"open my …"
///     is an instruction.
///   - "TRY THAT AGAIN", which `PassageEditRunner`'s step-6 race guard says. It
///     names no document and no app, so it cannot route to a fetch verb, and
///     the thing it asks for — re-read, re-locate, re-write — is the correct
///     recovery from that guard.
///
/// THE INDICATIVE ROW IS A CORRECTION, AND IT IS ONE CHARACTER WIDE. This list
/// held `"open it"` and caught nothing, while three shipped closed-world
/// refusals said `"opens it"` and `"can open"`:
///
///     "Notes isn't open — show_note opens it if you name a note."
///     "Safari isn't open — open_url can open a page in it."
///     "Pages isn't open — open_in_pages can open a document for you."
///
/// The user asked for the latest note and heard the first of those, after a
/// twenty-second wait, with "That's done — " in front of it. A model reads
/// "show_note opens it" as a thing to go and do exactly as it reads "open it"
/// that way — the grammatical mood is not what makes a sentence an errand, the
/// FETCHABLE ACT IN IT is — and `show_note` LAUNCHES NOTES, which is the one
/// act the guard that produced the sentence exists to refuse. A refusal that
/// routes back into the cold launch it just declined is not a refusal.
/// `theErrandVocabularyCatchesTheSentenceThatFired` runs all three.
enum PassageErrands {

    static let vocabulary = [
        "bring ", "point me", "pull up", "switch to", "click into", "click in",
        "put it in front", "open the document", "open it", "open my",
        "ask me again", "name the ", "give me ", "be more specific", "tell me which",
        // The indicative. Same act, described rather than commanded.
        "opens it", "opens the", "opens a ", "can open", "will open",
    ]

    /// The offending phrase, or nil.
    static func found(in sentence: String) -> String? {
        let lowered = sentence.lowercased()
        return vocabulary.first { lowered.contains($0) }
    }
}

