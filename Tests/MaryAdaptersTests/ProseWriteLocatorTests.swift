//
//  ProseWriteLocatorTests.swift
//  MaryAdaptersTests
//
//  WHICH ELEMENT, AND WHERE IN IT — the only decisions on the write path, and
//  the only ones a test can reach.
//
//  Accessibility cannot be exercised in a test process, so the write itself
//  (select, set, read back) is verified live by `mary-prose-probe`. Everything
//  that DECIDES is here: the locator is pure, takes strings, and answers with
//  a range or a refusal. That split is deliberate — a decision that could
//  reach an `AXUIElement` is a decision no test can run, and every decision on
//  this path is one a test must be able to run.
//
//  THE RULE, in the order it applies, each clause load-bearing:
//    1. The first candidate containing the passage EXACTLY ONCE wins
//       outright — checked across ALL candidates before any ambiguous one, so
//       a header that repeats the words can never outrank the body that has
//       them once.
//    2. Only then, several occurrences, decided by the hint — and refused if
//       the hint cannot separate them by a clear margin.
//    3. Otherwise the passage is not in anything the application is showing.
//
//  WHAT A REFUSAL PROTECTS. The thing being refused in clause 2 is
//  overwriting the wrong paragraph. A coin toss there does not produce a
//  wrong answer the user can see and correct; it produces a correct-looking
//  edit in the wrong place.
//

import Foundation
import Testing
@testable import MaryAdapters

@Suite struct ProseWriteLocatorTests {

    private func candidate(_ text: String) -> ProseTextCandidate {
        ProseTextCandidate(resolution: .mainWindowDescent, text: text)
    }

    /// The locator answers in Character offsets into the candidate's own
    /// string, which is what this reads back.
    private func slice(_ text: String, _ range: Range<Int>) -> String {
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: range.upperBound)
        return String(text[start..<end])
    }

    private func choose(
        _ texts: [String], passage: String, hint: Range<Int> = 0..<0
    ) -> ProseWriteChoice {
        ProseWriteLocator.choose(
            among: texts.map(candidate), passageText: passage, hint: hint)
    }

    // MARK: - Clause 1: one occurrence wins

    @Test func aSingleOccurrenceIsChosenOutright() throws {
        let body = "The tide came in overnight. The boats were gone."
        guard case .chosen(let target) = choose([body], passage: "The boats were gone")
        else {
            Issue.record("a unique passage must be chosen")
            return
        }
        #expect(target.index == 0)
        #expect(target.occurrences == 1)
        #expect(slice(body, target.range) == "The boats were gone")
    }

    /// THE CLAUSE THAT ORDERS THE OTHERS. A unique match is checked across
    /// EVERY candidate before an ambiguous one is considered anywhere — so a
    /// header element that happens to repeat the words cannot outrank the
    /// body that has them once.
    @Test func aUniqueMatchOutranksAnAmbiguousEarlierCandidate() throws {
        guard case .chosen(let target) = choose(
            ["draft draft draft", "the final draft"], passage: "draft")
        else {
            Issue.record("the unique candidate must win")
            return
        }
        #expect(target.index == 1, "the ambiguous first candidate must not be picked")
        #expect(target.occurrences == 1)
    }

    // MARK: - Clause 2: the hint, and the margin it must clear

    /// "Far nearer" is `PassageResolver.driftMargin` — the tree's existing
    /// spelling of "proximity is only evidence past this gap", deliberately
    /// not a second number invented for this rule. The filler below clears it
    /// with room to spare, so the test measures the RULE rather than the
    /// constant's current value.
    @Test func aFarNearerOccurrenceIsChosenByTheHint() throws {
        let filler = String(repeating: "x", count: PassageResolver.driftMargin * 2)
        let body = "alpha " + filler + " alpha"
        guard case .chosen(let target) = choose([body], passage: "alpha", hint: 0..<5)
        else {
            Issue.record("a clearly nearer occurrence should decide")
            return
        }
        #expect(target.range.lowerBound == 0)
        #expect(target.occurrences == 2)
    }

    /// TWO IDENTICAL PASSAGES SIDE BY SIDE ARE A COIN TOSS, and what a coin
    /// toss decides here is which of the user's paragraphs gets overwritten.
    @Test func anUndecidableTieIsRefusedRatherThanGuessed() {
        guard case .refused(let refusal) = choose(
            ["alpha alpha"], passage: "alpha", hint: 0..<5)
        else {
            Issue.record("neighbouring identical runs must refuse")
            return
        }
        guard case .ambiguous(let count) = refusal else {
            Issue.record("the refusal should name ambiguity, got \(refusal)")
            return
        }
        #expect(count == 2)
    }

    // MARK: - Clause 3, and the edges

    @Test func aPassageThatIsNowhereIsNotFound() {
        guard case .refused(let refusal) = choose(["the tide came in"], passage: "the moon")
        else {
            Issue.record("an absent passage must refuse")
            return
        }
        #expect(refusal == .notFound)
    }

    @Test func noCandidatesMeansNoTextElement() {
        guard case .refused(let refusal) = choose([], passage: "anything")
        else {
            Issue.record("nothing to search must refuse")
            return
        }
        #expect(refusal == .noTextElement)
    }

    /// AN EMPTY PASSAGE MATCHES EVERYWHERE AND THEREFORE NOWHERE. Refusing it
    /// as not-found keeps a malformed edit a spoken refusal rather than a
    /// crash in front of the user.
    @Test func anEmptyPassageIsRefused() {
        guard case .refused(let refusal) = choose(["some text"], passage: "")
        else {
            Issue.record("an empty passage must refuse")
            return
        }
        #expect(refusal == .notFound)
    }

    /// The offsets are into the CANDIDATE'S OWN string, which is the whole
    /// contract: a writer re-locates in the text its own element returned and
    /// never converts an offset that arrived from elsewhere.
    @Test func rangesIndexTheChosenCandidatesOwnText() throws {
        let second = "prologue\nthe tide came in"
        guard case .chosen(let target) = choose(
            ["unrelated first element", second], passage: "the tide came in")
        else {
            Issue.record("expected a match in the second candidate")
            return
        }
        #expect(target.index == 1)
        #expect(slice(second, target.range) == "the tide came in")
    }
}
