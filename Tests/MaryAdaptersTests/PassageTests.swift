//
//  PassageTests.swift
//  BonnieBrainTests
//
//  THE INCIDENT, PINNED. The user, in Pages:
//
//    "replace the Purpose section with the tighter version"
//
//  She called `type_at_cursor` — the only write verb that existed — typed the
//  new prose wherever the caret happened to be, and left the Purpose section
//  standing. Asked to fix it she was handed `characters 68–916 of 916` in her
//  prompt with no primitive anywhere that accepts an end offset, hand-wrote
//  AppleScript against `document 1`, hit the ghost document, and got
//  `-1728 errAENoSuchObject`.
//
//  `theLiveCase…` below is that sentence, mechanized. Everything else in this
//  file is the machinery that has to hold for it to keep working: the ladder
//  rung by rung, the tie-break as a TOTAL order (so "which one did you mean?"
//  is unreachable), the refusals that must stay refusals, and the arithmetic
//  of the four edits.
//

import Foundation
import Testing
@testable import MaryAdapters
@testable import MaryAdapters
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
    @Test func aVerbatimHitThatIsAUnitKeepsTheUnitsKind() {
        let decision = PassageWidening.locate(
            target: "Everything published under the imprint, including drafts.",
            in: purposeDoc, units: purposeUnits)
        #expect(decision.rung == .verbatim)
        #expect(decision.kind == .paragraph)
    }

    /// Rung 2. Spacing, punctuation, case and diacritics forgiven — and only
    /// reached because rungs 0 and 1 genuinely missed.
    @Test func normalizedRungForgivesSpacingAndPunctuation() {
        let decision = PassageWidening.locate(
            target: "Synthetic  media, disclosure", in: purposeDoc, units: purposeUnits)
        #expect(decision.rung == .normalized)
        #expect(decision.span == at("synthetic media disclosure"))
    }

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
    @Test func aBareWordWithNoPartNounIsTheWordItself() {
        let decision = PassageWidening.locate(
            target: "Purpose", in: purposeDoc, units: purposeUnits)
        #expect(decision.rung == .verbatim)
        #expect(decision.span == at("Purpose"))
    }

    /// Rung 3. Token overlap over paragraphs, using `AmbientRanker.tokens` —
    /// the one stopword list in this tree.
    @Test func tokenOverlapRungFindsTheParagraphThatIsAboutIt() {
        let decision = PassageWidening.locate(
            target: "imprint drafts", in: purposeDoc, units: purposeParagraphsOnly)
        #expect(decision.rung == .tokenOverlap)
        #expect(decision.span == scopeParagraph)
        #expect(decision.confidence == .exact)
    }

    /// THE FLOOR, in its own arithmetic. One of four words is 0.25 and does
    /// not qualify — a single incidental word must not carry a match. Three of
    /// three is 1.0 and does.
    @Test func minimumOverlapRejectsOneWordOutOfFour() {
        #expect(PassageWidening.overlapCandidates(
            "imprint aardvark badger crocodile",
            in: purposeDoc, units: purposeParagraphsOnly).isEmpty)
        #expect(PassageWidening.overlapCandidates(
            "imprint drafts published",
            in: purposeDoc, units: purposeParagraphsOnly).count == 1)
    }

    /// AND WHAT HAPPENS INSTEAD IS THE USER'S RULE. Rung 3 declining is not a
    /// refusal — it falls through to rung 4, which locates the one word that
    /// IS there and widens to the block around it. "Read wider, then decide
    /// alone."
    @Test func aRungThreeFloorFallsThroughToWideningNotToARefusal() {
        let decision = PassageWidening.locate(
            target: "imprint aardvark badger crocodile",
            in: purposeDoc, units: purposeParagraphsOnly)
        #expect(decision.rung == .widened)
        #expect(decision.span == scopeParagraph)
        #expect(decision.narrowerAlternative == at("imprint"))
    }

    /// Rung 4. Their words were a FRAGMENT of what is written; the fragment is
    /// found and then widened to the block that contains it, which begins
    /// where a block begins rather than mid-sentence.
    @Test func widenedRungLiftsAFragmentToItsEnclosingBlock() {
        let body = "Alpha one.\n\nThe budget forecast is unchanged this quarter.\n\nCharlie three."
        let middle = at("The budget forecast is unchanged this quarter.", in: body)
        // `.window` units on purpose: a world that can slice a document but
        // not parse its prose. Rung 3 only looks at paragraphs and sections,
        // so this reaches rung 4 the way a structure-less world would.
        let units = [
            PassageUnit(range: at("Alpha one.", in: body), kind: .window),
            PassageUnit(range: middle, kind: .window),
            PassageUnit(range: at("Charlie three.", in: body), kind: .window),
        ]
        let decision = PassageWidening.locate(
            target: "budget forecast summary", in: body, units: units)
        #expect(decision.rung == .widened)
        #expect(decision.span == middle)
        #expect(decision.narrowerAlternative == at("budget forecast", in: body))
    }

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
    @Test func theCapDoesNotApplyToASectionTheUserNamed() {
        let long = String(repeating: "sentence after sentence. ", count: 200)   // 5000 chars
        let body = "Purpose\n\n" + long
        let section = 0..<body.count
        let decision = PassageWidening.locate(
            target: "the Purpose section", in: body,
            units: [PassageUnit(range: section, label: "Purpose", level: 1, kind: .section)])
        #expect(decision.span == section)
        #expect(decision.span!.count > PassageWidening.maxSpan)
        #expect(decision.rung == .structural)
    }

    /// Nothing on any rung. The refusal is quoted from this tree, not written
    /// fresh: `XcodeEditError.noMatch`'s opening and
    /// `PagesPlugin.targetedOutcome`'s reasons, word for word. One phrasing
    /// for one fact.
    @Test func aTotalMissSpeaksInTheTreesOwnMissWords() {
        let decision = PassageWidening.locate(
            target: "aardvark", in: purposeDoc, units: purposeUnits)
        #expect(decision.span == nil)
        #expect(decision.rung == nil)
        #expect(decision.confidence == nil)
        #expect(decision.refusal?.hasPrefix("I couldn't find \"aardvark\" to change.") == true)
        #expect(decision.refusal?.contains(PassageWidening.missReason) == true)
        // The application-side half of this assertion went with Bonnie's
        // Pages adapter. What survives is the rule it was checking: a miss
        // explains itself in the resolver's own words, so every caller says
        // the same thing about the same failure.
    }

    /// The ladder STOPS. A rung-0 hit must not have to out-compete rung 3's
    /// fuzzy opinion about the same sentence.
    @Test func theLadderStopsAtTheFirstRungThatYieldsAnything() {
        let decision = PassageWidening.locate(
            target: "Everything published under the imprint, including drafts.",
            in: purposeDoc, units: purposeUnits)
        #expect(decision.rung == .verbatim)
        #expect(decision.trace.contains { $0.hasPrefix("rung 0 verbatim: 1") })
        #expect(!decision.trace.contains { $0.hasPrefix("rung 3") })
    }

    /// The part-nouns come off the back, the determiners off the front, and
    /// the NAME survives — including when the name is itself a noun that
    /// looks structural.
    @Test(arguments: [
        ("the Purpose section", "Purpose"),
        ("Purpose", "Purpose"),
        ("that whole Scope chapter", "Scope"),
        ("the resolveFocus function", "resolveFocus"),
        ("Introduction", "Introduction"),
        ("section", "section"),
    ])
    func structuralTargetStripsTheScaffoldingAndNothingElse(input: String, expected: String) {
        #expect(PassageWidening.structuralTarget(PassageWidening.cleanTarget(input)) == expected)
    }
}

// MARK: - The tie-break

@Suite struct PassageTieBreakTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private func candidate(
        _ range: Range<Int>, overlap: Double = 1.0, rung: PassageRung = .tokenOverlap
    ) -> PassageCandidate {
        PassageCandidate(range: range, overlap: overlap, kind: .paragraph, rung: rung)
    }

    /// TERM 1 — rung ascending. An exact hit beats a fuzzy one even when the
    /// fuzzy one accounts for more of the words.
    @Test func rungOutranksEverythingBelowIt() {
        let exact = candidate(500..<510, overlap: 0.1, rung: .verbatim)
        let fuzzy = candidate(0..<10, overlap: 1.0, rung: .widened)
        #expect(PassageWidening.precedes(exact, fuzzy, anchor: nil))
        #expect(!PassageWidening.precedes(fuzzy, exact, anchor: nil))
    }

    /// TERM 2 — overlap descending.
    @Test func moreOfWhatTheySaidWins() {
        let more = candidate(500..<510, overlap: 0.9)
        let less = candidate(0..<10, overlap: 0.5)
        #expect(PassageWidening.precedes(more, less, anchor: nil))
    }

    /// TERM 3 — nearest the attention anchor, and ONLY when there is one.
    /// With no anchor the term is skipped entirely rather than becoming
    /// distance-from-zero, which would silently mean "earliest".
    @Test func theAttentionAnchorBreaksAnOtherwiseEvenTie() {
        let early = candidate(0..<10)
        let late = candidate(100..<110)
        #expect(PassageWidening.precedes(late, early, anchor: 105))
        #expect(PassageWidening.precedes(early, late, anchor: nil))
    }

    /// TERM 4 — earliest in the document.
    @Test func earliestWinsWhenNothingElseSeparatesThem() {
        #expect(PassageWidening.precedes(candidate(10..<40), candidate(60..<90), anchor: nil))
    }

    /// TERM 5 — shortest span. The more surgical of two picks that start in
    /// the same place.
    @Test func shortestWinsAtTheSameStart() {
        #expect(PassageWidening.precedes(candidate(10..<20), candidate(10..<400), anchor: nil))
    }

    /// AND THAT IS ALL FIVE. Two survivors of terms 4 and 5 have the same
    /// lower bound and the same length — they are the same span, and which one
    /// "wins" cannot matter. This is what makes "ambiguous, ask the user"
    /// unreachable.
    @Test func afterAllFiveTermsTwoSurvivorsAreTheSameSpan() {
        let a = candidate(10..<40)
        let b = candidate(10..<40)
        #expect(!PassageWidening.precedes(a, b, anchor: nil))
        #expect(!PassageWidening.precedes(b, a, anchor: nil))
        #expect(a.range == b.range)
    }

    /// THE FIVE TERMS PROVED AS A LAW, not one term at a time. Everything
    /// above checks that a single term decides the case it was written for;
    /// this checks the property those terms exist to produce, because that is
    /// the one a later edit can break without failing any of them.
    ///
    /// `locate` sorts with `precedes` and then reads `ordered[0]` and
    /// `ordered[1]`. If `precedes` is not a STRICT WEAK ORDERING, `sorted` is
    /// entitled to return anything at all — so "she decides alone" would rest
    /// on whichever way an unspecified sort fell. Irreflexivity, asymmetry and
    /// transitivity are checked, and so is TRANSITIVITY OF THE INDUCED
    /// EQUIVALENCE, which is the one a stray `Double` breaks: a NaN overlap
    /// compares equal to everything and unequal to itself, and would make
    /// three candidates pairwise-equivalent in a way that is not an
    /// equivalence at all. (`overlap` is guarded against 0/0 at both sites
    /// that compute it; this is what keeps that true.)
    ///
    /// The last assertion is the contract's own claim, stated as a test:
    /// candidates the order CANNOT SEPARATE are the same span, so there is
    /// never a real question left for the user to answer.
    @Test func theFiveTermsAreAStrictWeakOrdering() {
        var grid: [PassageCandidate] = []
        for rung in PassageRung.allCases {
            for overlap in [0.0, 0.5, 1.0] {
                for lower in [0, 10] {
                    for count in [5, 30] {
                        grid.append(PassageCandidate(
                            range: lower..<(lower + count), overlap: overlap,
                            kind: .paragraph, rung: rung))
                    }
                }
            }
        }
        for anchor in [nil, 12] as [Int?] {
            func lt(_ a: PassageCandidate, _ b: PassageCandidate) -> Bool {
                PassageWidening.precedes(a, b, anchor: anchor)
            }
            func equivalent(_ a: PassageCandidate, _ b: PassageCandidate) -> Bool {
                !lt(a, b) && !lt(b, a)
            }
            for a in grid {
                #expect(!lt(a, a), "irreflexive")
                for b in grid {
                    #expect(!(lt(a, b) && lt(b, a)), "asymmetric")
                    if equivalent(a, b) { #expect(a.range == b.range, "inseparable ⇒ same span") }
                    for c in grid {
                        if lt(a, b), lt(b, c) { #expect(lt(a, c), "transitive") }
                        if equivalent(a, b), equivalent(b, c) {
                            #expect(equivalent(a, c), "equivalence is transitive")
                        }
                    }
                }
            }
        }
    }

    /// An anchor INSIDE a candidate is not "near" it — it is where the user
    /// is, so the distance is zero and no other candidate can beat it on this
    /// term.
    @Test func anAnchorInsideASpanIsDistanceZero() {
        #expect(PassageWidening.distance(from: 10..<40, to: 25) == 0)
        #expect(PassageWidening.distance(from: 10..<40, to: 5) == 5)
        #expect(PassageWidening.distance(from: 10..<40, to: 44) == 5)
    }

    /// The anchor is TEXT-DERIVED. Words that are not in the body — a header,
    /// a text box, a comment field — yield no anchor at all, and the rung is
    /// skipped rather than fudged.
    @Test func attentionFromTextOutsideTheBodyIsNoAnchorAtAll() {
        let body = "Alpha one. Bravo two."
        #expect(PassageAttention(text: "Bravo").anchor(in: body) == 11)
        #expect(PassageAttention(text: "a running header").anchor(in: body) == nil)
        #expect(PassageAttention().anchor(in: body) == nil)
    }

    /// A selection is only usable if it fits the body it is being applied to —
    /// which is exactly the check that stops an AX offset (UTF-16, counting
    /// headers and text boxes) from being read as a body-text offset.
    @Test func anOutOfBoundsSelectionIsNotAnAnchor() {
        let body = "Alpha one. Bravo two."
        #expect(PassageAttention(validatedSelection: 4..<9).anchor(in: body) == 4)
        #expect(PassageAttention(validatedSelection: 400..<900).anchor(in: body) == nil)
    }
}

// MARK: - Confidence

@Suite struct PassageConfidenceTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private func candidate(_ overlap: Double) -> PassageCandidate {
        PassageCandidate(range: 0..<10, overlap: overlap, kind: .paragraph, rung: .tokenOverlap)
    }

    /// One candidate: there was nothing else it could have been.
    @Test func oneCandidateIsExact() {
        #expect(PassageWidening.confidence(winner: candidate(1.0), runnerUp: nil) == .exact)
    }

    /// The margin, at and around `decisiveMargin` (0.25 — one extra word out
    /// of four). `<` is contested, so matching exactly as many of the user's
    /// words as the runner-up is always contested.
    @Test(arguments: [
        (1.0, 1.0, PassageConfidence.contested),
        (1.0, 0.8, PassageConfidence.contested),
        (1.0, 0.76, PassageConfidence.contested),
        (1.0, 0.75, PassageConfidence.chosen),
        (1.0, 0.5, PassageConfidence.chosen),
    ])
    func theMarginDecidesChosenFromContested(
        winner: Double, runnerUp: Double, expected: PassageConfidence
    ) {
        #expect(PassageWidening.confidence(
            winner: candidate(winner), runnerUp: candidate(runnerUp)) == expected)
    }

    /// End to end: two verbatim copies of the same phrase are a tie, so the
    /// pick still happens — she decides alone — but the report names the
    /// runner-up, which is what makes an unattended wrong pick recoverable.
    @Test func twoIdenticalPassagesAreContestedAndTheRunnerUpIsNamed() {
        let body = "We reviewed the budget forecast today.\n\nAgain: the budget forecast is unchanged."
        let decision = PassageWidening.locate(
            target: "the budget forecast", in: body, units: [])
        #expect(decision.confidence == .contested)
        #expect(decision.runnerUp != nil)
        #expect(decision.span!.lowerBound < decision.runnerUp!.range.lowerBound)
    }

    /// ONE SPAN IS NEVER ITS OWN RIVAL. Rung 4 reaches a block through EVERY
    /// consecutive run of the target's words that lands inside it, so a target
    /// with two disjoint fragments in one paragraph — "alpha beta … victor
    /// whiskey" — used to nominate that paragraph twice: identical range,
    /// identical overlap, differing only in which fragment was the evidence.
    /// The duplicate then became its own runner-up, which reported
    /// `.contested` about a pick nothing competed with and offered the user
    /// the span just chosen as the alternative to it. The two spellings of the
    /// fix are pinned together because either alone would let it back: rung 4
    /// keeps one candidate per block, and the runner-up must be a different
    /// span whatever the rung.
    @Test func oneSpanIsNeverItsOwnRunnerUp() {
        // Overlap is held at 4/11 so rung 3 provably stays out and this is
        // really rung 4 being tested.
        let body = "Alpha beta drifting along and victor whiskey at the end."
        let units = [PassageUnit(range: 0..<body.count, kind: .paragraph)]
        let decision = PassageWidening.locate(
            target: "alpha beta zulu yankee xray quebec romeo sierra tango victor whiskey",
            in: body, units: units)
        #expect(decision.rung == .widened)
        #expect(decision.span == 0..<body.count)
        #expect(decision.runnerUp == nil)
        #expect(decision.confidence == .exact)
        // And the evidence named is the EARLIEST fragment, not whichever way
        // an unstable sort fell.
        #expect(decision.narrowerAlternative == 0..<"Alpha beta".count)
    }
}

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
    @Test func ambiguousAfterDriftRefusesTwoCloseCopies() {
        let body = "Bravo two.\n\nfiller\n\nBravo two."
        let held = passage(text: "Bravo two.", range: 0..<10, body: "something else entirely")
        let outcome = PassageResolver.anchor(held, in: body)
        #expect(outcome == .ambiguousAfterDrift(count: 2))
        #expect(PassageResolver.refusal(outcome, for: held)?.contains("appears 2 times") == true)
    }

    /// Far enough apart to be evidence: one occurrence is more than a maximal
    /// edit's worth of movement closer than the other.
    @Test func farApartCopiesResolveToTheNearerOne() {
        let filler = String(repeating: "x", count: PassageResolver.driftMargin + 100)
        let body = "Bravo two.\n\n" + filler + "\n\nBravo two."
        let held = passage(text: "Bravo two.", range: 0..<10, body: "something else entirely")
        #expect(PassageResolver.anchor(held, in: body) == .reanchored(0..<10, drift: 0))
    }

    /// The margin is the widening cap, read from there rather than repeated.
    @Test func driftMarginIsTheMaximalEditsWorthOfMovement() {
        #expect(PassageResolver.driftMargin == PassageWidening.maxSpan)
    }
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
    @Test func deleteAtTheEdgesTakesTheSeparatorWithIt() {
        let first = PassageUnit(range: at("Alpha one.", in: body), kind: .paragraph)
        #expect(PassageEdit.apply(.delete, text: "", to: first, in: body).newBody
            == "Bravo two.\n\nCharlie three.")
        let last = PassageUnit(range: at("Charlie three.", in: body), kind: .paragraph)
        #expect(PassageEdit.apply(.delete, text: "", to: last, in: body).newBody
            == "Alpha one.\n\nBravo two.")
    }

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
    @Test func aPhraseGetsBareTextAndOneSpaceAtTheSeam() {
        let line = "The budget forecast is unchanged."
        let phrase = PassageUnit(range: at("budget forecast", in: line), kind: .phrase)
        #expect(PassageEdit.apply(.replace, text: "revenue outlook", to: phrase, in: line).newBody
            == "The revenue outlook is unchanged.")
        // THE WELD, in the shape it shipped in: a bare payload, no blank lines,
        // and two words that must not run together.
        #expect(PassageEdit.apply(.insertAfter, text: "summary", to: phrase, in: line).newBody
            == "The budget forecast summary is unchanged.")
        #expect(PassageEdit.apply(.insertBefore, text: "the", to: phrase, in: line).newBody
            == "The the budget forecast is unchanged.")
        // And a caller who ALREADY spaced their payload gets one space, not two.
        // That is the same mistake in the other direction, and it is why the
        // rule looks at both facing edges rather than always inserting.
        #expect(PassageEdit.apply(.insertAfter, text: " summary", to: phrase, in: line).newBody
            == "The budget forecast summary is unchanged.")
        #expect(PassageEdit.apply(.insertBefore, text: "the ", to: phrase, in: line).newBody
            == "The the budget forecast is unchanged.")
        // A BLOCK IS UNTOUCHED BY ANY OF THIS. It supplies its own blank lines
        // and trims the payload to match; `phraseSeparator` must never reach it.
        let block = "Alpha one.\n\nBravo two."
        let unit = PassageUnit(range: at("Bravo two.", in: block), kind: .paragraph)
        #expect(PassageEdit.apply(.insertAfter, text: "Charlie.", to: unit, in: block).newBody
            == "Alpha one.\n\nBravo two.\n\nCharlie.")
    }

    /// The seam rule alone, both edges, in the order they touch.
    ///
    /// `left` and `right` NAME THE SEAM RATHER THAN THE ROLES, because which of
    /// them is the passage and which is the new wording flips between
    /// `insertBefore` and `insertAfter` — and getting that backwards is the
    /// whole failure rather than a detail of it.
    @Test func phraseSeparatorIsOneSpaceOrNone() {
        let table: [(left: String, right: String, seam: String)] = [
            // The only shape that gets a space: two non-space characters facing.
            ("forecast", "summary", " "),
            // Either side already carrying whitespace means the caller meant it.
            ("forecast", " summary", ""),
            ("forecast ", "summary", ""),
            ("forecast\n", "summary", ""),
            ("forecast", "\nsummary", ""),
            // An empty side has no facing edge at all, so there is no seam.
            ("", "summary", ""),
            ("forecast", "", ""),
            ("", "", ""),
        ]
        for row in table {
            #expect(PassageEdit.phraseSeparator(left: row.left, right: row.right) == row.seam,
                    "\"\(row.left)\" | \"\(row.right)\"")
        }
    }

    /// THE REPORT VERB FOLLOWS THE REDUCTION, and this is the sentence the user
    /// would otherwise reach for undo over.
    ///
    /// `.replace` now goes through `minimalChange`, so "here is the Background
    /// section again, one sentence different" writes that one sentence and
    /// leaves the other five paragraphs exactly as they were. "Done — I replaced
    /// the Background section" is then a bigger claim than the edit; the user
    /// hears their section as having been rewritten, and goes looking.
    @Test(arguments: [
        (0.02, "worked that into the Background section"),
        (0.32, "worked that into the Background section"),
        (0.34, "replaced the Background section"),
        (1.0, "replaced the Background section"),
    ])
    func replaceSaysWorkedIntoWhenItOnlyTouchedAFraction(
        fraction: Double, clause: String
    ) {
        let unit = PassageUnit(range: 0..<100, label: "Background", kind: .section)
        #expect(PassageEdit.summaryClause(
            .replace, unit: unit, changedFraction: fraction) == clause)
    }

    /// THE DEFAULT IS THE WHOLE PASSAGE, so every caller that never narrowed
    /// anything — `apply` itself, and the three operations that pass straight
    /// through `writeSpan` — reads exactly as it did before the ratio existed.
    @Test func theClauseDefaultsToTheWholeThingAndOnlyReplaceHasTwoVerbs() {
        let unit = PassageUnit(range: 0..<100, label: "Background", kind: .section)
        #expect(PassageEdit.summaryClause(.replace, unit: unit)
            == "replaced the Background section")
        for operation in PassageOperation.allCases where operation != .replace {
            #expect(PassageEdit.summaryClause(operation, unit: unit, changedFraction: 0.01)
                == PassageEdit.summaryClause(operation, unit: unit),
                "\(operation) must not change its verb with the ratio")
        }
        #expect(PassageEdit.wovenFraction == 1.0 / 3.0)
    }

    /// The runner's half of the same fact. A widened anchor can legitimately be
    /// LONGER than the passage — `uniqueAnchor` grows outward past its edges —
    /// and 1 is what that means: as much as the whole thing.
    @Test func theReductionIsAFractionAndNeverExceedsOne() {
        #expect(PassageEditRunner.reduction("abc", of: "abcdefghij") == 0.3)
        #expect(PassageEditRunner.reduction("abcdefghij", of: "abcdefghij") == 1)
        #expect(PassageEditRunner.reduction(String(repeating: "x", count: 500), of: "abc") == 1)
        #expect(PassageEditRunner.reduction("anything", of: "") == 1)
    }

    /// `priorBody` is what `ContentUndoStore.record` keeps and
    /// `revert_last_edit` hands back. It has to round-trip exactly.
    @Test(arguments: PassageOperation.allCases)
    func priorBodyRoundTripsForEveryOperation(operation: PassageOperation) {
        let result = PassageEdit.apply(operation, text: "Delta four.", to: bravo, in: body)
        #expect(result.priorBody == body)
        #expect(result.newBody != body)
        #expect(!result.summaryClause.isEmpty)
        #expect(!result.summaryClause.hasSuffix("."))
    }

    /// THE RANGED WRITER'S HALF. `anchorText` → `replacement` must reproduce
    /// `newBody` exactly, because that substitution — words in, words out — is
    /// the only thing a writer in a foreign coordinate space is ever handed.
    @Test(arguments: PassageOperation.allCases)
    func anchorTextAndReplacementReproduceTheNewBody(operation: PassageOperation) {
        let result = PassageEdit.apply(operation, text: "Delta four.", to: bravo, in: body)
        #expect(body.contains(result.anchorText))
        #expect(body.replacingOccurrences(of: result.anchorText, with: result.replacement)
            == result.newBody)
    }

    /// `changedRange` is informational and must still be right, or the
    /// debugger line it feeds is a lie.
    @Test func changedRangePointsAtTheNewTextInTheNewBody() {
        let result = PassageEdit.apply(.insertAfter, text: "Delta four.", to: bravo, in: body)
        #expect(PassageWidening.substring(of: result.newBody, result.changedRange) == "Delta four.")
    }

    /// An out-of-date range is the case this whole design assumes will happen.
    /// Clamped, never trapped — crashing on it would be the loudest possible
    /// way to lose a document.
    @Test func anOverrunRangeIsClampedRatherThanTrapped() {
        let unit = PassageUnit(range: 900..<9000, kind: .paragraph)
        let result = PassageEdit.apply(.replace, text: "Delta four.", to: unit, in: body)
        #expect(result.newBody == body + "Delta four.")
    }
}

// MARK: - The registry

@Suite struct PassageRegistryTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private func mint(
        _ registry: PassageRegistry, text: String, range: Range<Int>,
        body: String = "Alpha one.\n\nBravo two.", at now: Date = Date()
    ) -> Passage? {
        registry.mint(
            place: .application("quill"), documentKey: "/tmp/draft.pages", documentTitle: "Draft",
            text: text, bodyHash: ContentUndoStore.hash(body), bodyLength: body.count,
            range: range, unitKind: .paragraph, locatorNote: "the part with that heading",
            provenance: .recipeRead, at: now)
    }

    /// IDENTITY IS `world|documentKey|hash(text)`, so reading the same passage
    /// twice keeps calling it `[S1]` — even after the offsets moved, which is
    /// exactly what identifying by text means.
    @Test func mintingIsIdempotentByIdentityNotByRange() {
        let registry = PassageRegistry()
        let first = mint(registry, text: "Bravo two.", range: 12..<22)
        let again = mint(registry, text: "Bravo two.", range: 40..<50, body: "grown")
        let other = mint(registry, text: "Alpha one.", range: 0..<10)
        #expect(first?.handle == "S1")
        #expect(again?.handle == "S1")
        #expect(other?.handle == "S2")
        // The hint and the body hash are refreshed; the handle is not.
        #expect(again?.range == 40..<50)
    }

    /// `[S1]`, `s1`, ` [S1] ` — however a model writes it back.
    @Test(arguments: ["S1", "s1", " [S1] ", "[s1]"])
    func resolveIsTolerantAboutSpelling(reference: String) {
        let registry = PassageRegistry()
        let minted = mint(registry, text: "Bravo two.", range: 12..<22)!
        #expect(registry.resolve(reference) == .live(minted))
        #expect(registry.resolve("P9") == .unknown)
    }

    /// THE BLANK FAILURE THIS REPLACES: without a forwarding address, "make it
    /// shorter still" resolves to nothing thirty seconds after Mary herself
    /// changed the passage.
    @Test func supersedeReportsItsReplacement() {
        let registry = PassageRegistry()
        let old = mint(registry, text: "Bravo two.", range: 12..<22)!
        let new = mint(registry, text: "Bravo, revised.", range: 12..<27)!
        registry.supersede(old.handle, with: new)
        #expect(registry.resolve(old.handle) == .superseded(replacedBy: new.handle))
        #expect(registry.resolve(new.handle) == .live(new))
    }

    /// PRUNING IS KEYED TO THE AMBIENT STORE'S OWN READ WINDOW, and that
    /// equality is the invariant: the prompt shows handles because a
    /// `namedRead` fact renders beside them, so a handle the prompt can see
    /// must always be a handle the tool accepts. They live and die together.
    @Test func pruningNeverEvictsAHandleALiveFactStillNames() {
        let registry = PassageRegistry()
        let store = AmbientContextStore()
        let minted = Date()
        let passage = mint(registry, text: "Bravo two.", range: 12..<22, at: minted)!
        store.register(
            AmbientFact(
                world: .applications, application: "quill", slot: .read("bravo"),
                content: passage.text,
                subject: "Draft", provenance: .recipeRead, registration: .askedFor,
                capturedAt: minted),
            at: minted)

        let window = AmbientFact.defaultRetention(slot: .read(""))
        #expect(PassageRegistry.retention == window)

        let lastMoment = minted.addingTimeInterval(window)
        #expect(!store.facts(at: lastMoment).isEmpty)
        #expect(registry.resolve(passage.handle, at: lastMoment) == .live(passage))

        let past = minted.addingTimeInterval(window + 1)
        #expect(store.facts(at: past).isEmpty)
        #expect(registry.resolve(passage.handle, at: past) == .unknown)
    }

    /// The cap is derived from the store's own arithmetic, not picked: four
    /// named reads per world, the PASSAGE-BEARING worlds (watched minus the
    /// Keynote canvas, whose reads mint refs and never passages), doubled
    /// because an edit supersedes rather than replaces.
    @Test func theCapIsDerivedFromTheStoresOwnNumbers() {
        // NO COMPILED PASSAGE-BEARING COUNT. Bonnie multiplied by the number
        // of worlds whose documents held passages, and had to explain in a
        // comment that a taught application earned its share a different way.
        // Every application earns it the same way now — `hasEyes` plus a
        // backing — so the cap rests on the store's own number and the live
        // roster, and there is nothing to keep in step.
        #expect(PassageRegistry.cap
            == AmbientContextStore.namedReadCap
                * PassageRegistry.passageBearingPlaceCount * 2)
    }

    /// The backstop bounds a pathological turn that mints faster than twenty
    /// minutes can forget. Oldest first, like `capNamedReads`.
    @Test func theCapEvictsOldestFirst() {
        let registry = PassageRegistry()
        let start = Date()
        // MINT PAST THE CAP, derived rather than counted. This used to mint a
        // literal 30 against a cap of 24; a fourth watched world moved the cap
        // to 32 and the literal silently stopped overflowing it, so the test
        // asserted eviction while evicting nothing. Deriving the count is what
        // stops the next world from doing it again.
        let overflow = PassageRegistry.cap + 8
        let handles = (0..<overflow).map {
            mint(registry, text: "passage number \($0)", range: 0..<5,
                 at: start.addingTimeInterval(Double($0)))!.handle
        }
        #expect(registry.live().count == PassageRegistry.cap)
        #expect(registry.resolve(handles[overflow - 1]) != .unknown)
        #expect(registry.resolve(handles[0]) == .unknown)
    }

    /// A passage is a located piece of a DOCUMENT. `.calendar` has no body
    /// text and `.typer` is a pair of hands; a handle for either would be one
    /// the prompt could show and no writer could ever satisfy.
    @Test(arguments: AmbientWorld.allCases)
    func onlyObservedProseWorldsGetHandles(world: AmbientWorld) {
        let registry = PassageRegistry()
        let minted = registry.mint(
            world: world, documentKey: "k", documentTitle: "t", text: "words",
            bodyHash: "abc", bodyLength: 5, range: 0..<5, unitKind: .paragraph,
            provenance: .recipeRead)
        #expect((minted != nil) == world.hasEyes)
        #expect(Passage.canHold(world) == world.hasEyes)
    }

    /// Test isolation — a process-wide box must never leak between suites.
    @Test func clearEmptiesTheBox() {
        let registry = PassageRegistry()
        let minted = mint(registry, text: "Bravo two.", range: 12..<22)!
        registry.clear()
        #expect(registry.resolve(minted.handle) == .unknown)
        #expect(registry.live().isEmpty)
    }
}

// MARK: - The one coordinate space

@Suite struct PassageSpaceTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    /// A ONE-CASE ENUM IS THE POINT. If a second case ever appears here,
    /// something has decided that an AX offset or a 1-based AppleScript
    /// `character N` may travel through this system as a number — and both of
    /// those have already produced a live failure (`ViewportProvenance.diverged`
    /// for the first, `-1728` for the second). Converting locally at the write
    /// site is the design; a second case is the bug.
    @Test func thereIsExactlyOneCoordinateSpace() {
        #expect(PassageSpace.allCases.count == 1)
        #expect(PassageSpace.allCases == [.documentText])
    }

    /// A passage carries the freshness vocabulary the ambient store already
    /// uses, so a handle and the fact beside it can never claim different ages
    /// for the same read.
    @Test func aPassageSpeaksTheAmbientFreshnessVocabulary() {
        let passage = Passage(
            handle: "S1", place: .application("forge"), documentKey: "/tmp/a.swift", documentTitle: "a.swift",
            text: "func resolveFocus() {}", bodyHash: "abc", bodyLength: 22, range: 0..<22,
            unitKind: .declaration, provenance: .recipeRead)
        #expect(passage?.space == .documentText)
        #expect(passage?.provenance == .recipeRead)
        #expect(passage?.opening() == "func resolveFocus() {}")
    }
}

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

@Suite struct PassageRefusalWordingTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    private func passage(
        text: String = "This document sets out what we are for.",
        title: String = "Essay"
    ) -> Passage {
        let body = "Purpose\n\n" + text
        return Passage(
            handle: "S1", place: .application("quill"), documentKey: "/Users/x/Essay.pages",
            documentTitle: title, text: text,
            bodyHash: ContentUndoStore.hash(body), bodyLength: body.count,
            range: 9..<(9 + text.count), unitKind: .paragraph, provenance: .recipeRead)!
    }

    /// EVERY REFUSAL THIS PATH OWNS, AND THE CLASS RATHER THAN THE INSTANCE.
    ///
    /// The switch below has no `default`, so a new `PassageWriteError` case does
    /// not compile until it is listed here — which is the whole point: the
    /// sentence that fired `OPEN_IN_PAGES` was not a careless one, it was a
    /// helpful one, and the next helpful one will be written by somebody who has
    /// never read this paragraph.
    ///
    /// ONE KNOWN ERRAND SURVIVES IN THE PASSAGE PATH AND IS NOT COVERED HERE:
    /// `PassageWidening`'s `maxSpan` refusal still ends "Tell me the heading, or
    /// give me the exact words, and I'll do just that piece." That file is not
    /// in this pass's hands; the sentence is named here so the next one to touch
    /// it does not have to find it.
    @Test func noPassageRefusalReadsAsAnErrand() {
        let errors: [PassageWriteError] = [
            .documentMoved(expected: "Essay", found: "Other"),
            .documentMoved(expected: "Essay", found: nil),
            .passageGone(opening: "This document sets out", document: "Essay"),
            .spanTooLarge(characters: 9000, limit: PassageWidening.maxSpan),
            // THE PAYLOAD IS THE CALLER'S, NOT THE ENUM'S, so a neutral one is
            // what belongs here — this pins the FRAME. Both live payloads are
            // composed elsewhere and both currently read as errands:
            // `ScrivenerStructure.cannotWriteBecause` deliberately routes to
            // `open_in_scrivener` + `type_at_cursor` (the verb that does work
            // there, which is the one legitimate case), and
            // `PagesWriteRefusal.writeError` says "Click into the document and
            // ask me again" on three of its six branches, which is not.
            //
            // `cannotWriteBecause` IS PINNED NOW, one suite over: it is on
            // `ScrivenerPlugin.refusals`, and `PluginCatalogTests
            // .noRefusalReadsAsAnErrand` names it as Rule 2's single exemption
            // with the reason. It is no longer "the one known errand nothing
            // covers"; it is the one known errand covered by name.
            .worldCannotWrite(.application("manuscript"), why: "its autosave would write over it."),
            .axRefused(detail: "the setter answered -25205."),
            // TextEdit forced this case into existence: with no Accessibility
            // tier to blame, routing an ambiguity through `.axRefused` would
            // have said "the app wouldn't let me set the text" about an app
            // that refused nothing. The ambiguity is OURS.
            .ambiguousInDocument(count: 3, document: "Untitled 21"),
            .verificationFailed(document: "Essay"),
            // The writer's own in-session content guard — typing raced the
            // write. States the condition and the standing repair; no errand.
            .raced(document: "Essay"),
        ]
        for error in errors {
            switch error {
            case .documentMoved, .passageGone, .spanTooLarge,
                 .worldCannotWrite, .axRefused, .verificationFailed,
                 .ambiguousInDocument, .raced:
                break
            }
            let spoken = try! #require(error.errorDescription)
            #expect(PassageErrands.found(in: spoken) == nil,
                    "\(error) says \"\(PassageErrands.found(in: spoken) ?? "")\": \(spoken)")
        }

        let held = passage()
        let outcomes: [AnchorOutcome] = [.gone, .ambiguousAfterDrift(count: 3)]
        for outcome in outcomes {
            switch outcome {
            case .exact, .reanchored, .gone, .ambiguousAfterDrift: break
            }
            let spoken = try! #require(PassageResolver.refusal(outcome, for: held))
            #expect(PassageErrands.found(in: spoken) == nil,
                    "\(outcome) says \"\(PassageErrands.found(in: spoken) ?? "")\": \(spoken)")
        }

        for world in AmbientWorld.watched {
            let spoken = PassageEditRunner.noDocumentMessage(.lane(world))
            #expect(PassageErrands.found(in: spoken) == nil, "\(spoken)")
        }
        #expect(PassageErrands.found(in: PassageRecipes.noWorldMessage) == nil,
                "\(PassageRecipes.noWorldMessage)")
        #expect(PassageErrands.found(in: PassageWidening.missReason) == nil,
                "\(PassageWidening.missReason)")
    }

    /// THE VOCABULARY ITSELF HAS TO BITE, or the test above passes by describing
    /// nothing. This is the sentence that shipped, run through it.
    @Test func theErrandVocabularyCatchesTheSentenceThatFired() {
        #expect(PassageErrands.found(
            in: "I couldn't find \"Background\" to change — it isn't in Essay any more. "
                + "Point me at it again and I'll pick it up.") == "point me")
        #expect(PassageErrands.found(
            in: "I can't see a document open in Pages right now — bring the one you mean "
                + "up and ask me again.") == "bring ")
        #expect(PassageErrands.found(
            in: "Pages isn't showing me any text I can work with. Click into the document "
                + "and ask me again.") == "click into")
        // And it does not fire on a description of a state. THE NEAR MISS IS
        // PINNED ON PURPOSE: "a document open in Pages" is one character away
        // from the entry "open it", and both refusals that survived this pass
        // contain the phrase — so if that entry is ever loosened to bare "open",
        // it is these two lines that say so rather than a green suite.
        #expect(PassageErrands.found(
            in: "I can't see a document open in Pages right now, so there's nothing in "
                + "front of me to look in.") == nil)
        #expect(PassageErrands.found(
            in: "A document open in Xcode, Pages or Scrivener is what I can work in.") == nil)
        #expect(PassageErrands.found(in: "Open it and I'll take another look.") == "open it")

        // THE THREE THAT SHIPPED, verbatim, and the reason the list grew a row.
        // Each named a REGISTERED RECIPE in the INDICATIVE, and each of those
        // recipes starts the app the guard exists not to start. The first is
        // the sentence the user actually heard when they asked for the latest
        // note they had made.
        #expect(PassageErrands.found(
            in: "Notes isn't open — show_note opens it if you name a note.") == "opens it")
        #expect(PassageErrands.found(
            in: "Safari isn't open — open_url can open a page in it.") == "can open")
        #expect(PassageErrands.found(
            in: "Pages isn't open — open_in_pages can open a document for you.") == "can open")
        // And Scrivener's, which the imperative row already caught — it is here
        // so the four that were rewritten together are read together.
        #expect(PassageErrands.found(
            in: "Novel isn't open in Scrivener — open it and ask again; I don't "
                + "touch a project's files while it's closed.") == "open it")

        // THE REPLACEMENTS, run through the widened list. This is the half that
        // makes the row above worth having: a vocabulary that bites the old
        // sentences and the new ones equally would have forced a wording nobody
        // could write.
        // CLOSED-PLACE SENTENCES ARE BUILT, NOT ENUMERATED. Bonnie had a case
        // per compiled application here and iterated them; Mary composes the
        // sentence from an application's name and what a relaunch would cost,
        // so the pins are over the SHAPES rather than a roster.
        for sentence in [
            ClosedWorld.sentence(app: "TextEdit"),
            ClosedWorld.sentence(app: "TextEdit", lost: "a new window would have none of the notes you had open"),
            ClosedWorld.nothingOpenSentence(app: "TextEdit", subject: "A note"),
        ] {
            #expect(PassageErrands.found(in: sentence) == nil,
                    "a closed-place sentence names an errand: \(sentence)")
        }
    }

    /// THE SPLIT. "The words are not in the document" and "the words are in the
    /// document and the surface I write through could not reach them" are
    /// different facts that the user acts on differently — and until now they
    /// were the SAME SENTENCE, character for character, in two files.
    ///
    /// That is how "the insertions didn't take — the passage wasn't found" came
    /// to be said about a document `pages_body` had read in full and quoted
    /// accurately one turn earlier. The passage was found. It sat past a page
    /// seam, in the half of a page-partitioned document that Accessibility does
    /// not hand over.
    @Test func theResolversMissAndTheWritersMissAreDifferentSentences() {
        let held = passage()
        let drifted = try! #require(PassageResolver.refusal(.gone, for: held))
        let unreachable = try! #require(PassageWriteError
            .passageGone(opening: held.opening(), document: "Essay").errorDescription)
        #expect(drifted != unreachable)
        // ONE IMPLEMENTATION OF THE DRIFT SENTENCE, and the resolver owns it.
        #expect(drifted == PassageResolver.driftedSentence(
            opening: held.opening(), document: "Essay"))
        // NEITHER MAY ASSERT ABSENCE. The prompt's own doctrine — "NEVER tell
        // the user that a passage, a section or a subject isn't in their work" —
        // was being obeyed by the voice while a tool handed her the claim.
        for sentence in [drifted, unreachable] {
            #expect(!sentence.lowercased().contains("isn't in"), "\(sentence)")
            #expect(!sentence.lowercased().contains("is not in"), "\(sentence)")
            #expect(!sentence.lowercased().contains("any more"), "\(sentence)")
        }
        // The drift sentence says what is TRUE whoever moved it.
        #expect(drifted.contains("has changed in Essay since I picked it up"))
        // The writer's says the words were there and the channel was the limit.
        #expect(unreachable.contains("couldn't reach it"))
        #expect(unreachable.contains("nothing has changed"))
    }

    /// AND IT MUST NOT COLLAPSE INTO THE MISS-BY-PHRASE SENTENCE EITHER. Three
    /// different facts, three different things for the user to do: the phrase
    /// never matched anything; the part they named has moved on; the part is
    /// there and could not be written. `PassageWidening.missReason` owns the
    /// first and is untouched by this.
    @Test func theDriftSentenceIsNotTheMissSentence() {
        let drifted = PassageResolver.driftedSentence(opening: "Background", document: "Essay")
        #expect(!drifted.contains(PassageWidening.missReason))
        #expect(!PassageWidening.missReason.contains("picked it up"))
    }
}
