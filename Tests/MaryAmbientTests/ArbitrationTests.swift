//
//  ArbitrationTests.swift
//  MaryAmbientTests
//
//  WHAT: The arbitration procedure, on a domain with no pages and no skills in it.
//  OUT:  Arbitration.run
//  PIN:  A TOY DOMAIN IS THE POINT. These rules — every candidate gets a
//        decision, terms are compared in order and never summed, a tie is a
//        question, a floor admits — are the PROCEDURE's, not any domain's, and a
//        suite written against real page rows would prove them only for pages.
//        The domain below is three integers and a label.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct ArbitrationTests {

    // MARK: - A domain made of nothing in particular

    struct Thing: Sendable, Equatable {
        var id: Int
        var label: String
        var kind: String = "thing"
        /// What the gate will say about it.
        var standing: ArbitrationStanding = .offered
        /// A note the domain wants said instead of "something else won".
        var note: String?
    }

    struct Evidence: ArbitrationEvidence {
        var lexical = 0
        var semantic = 0
        var structure = 0
        static var empty: Evidence { Evidence() }
        var total: Int { lexical + semantic + structure }
    }

    struct Domain: ArbitrationDomain {
        /// Which candidates the words reached, supplied by the test rather than
        /// derived — the naming ladder is its own component with its own suite.
        var reached: [Int: (points: Int, basis: String)] = [:]
        var floor = 100
        var allowsFallback = false
        var lexicalCalls = Counter()

        func identity(of candidate: Thing) -> Int { candidate.id }
        func label(of candidate: Thing) -> String { candidate.label }
        func kindWord(of candidate: Thing) -> String { candidate.kind }
        func standing(of candidate: Thing) -> ArbitrationStanding { candidate.standing }

        func lexical(
            goal: String, among candidates: [Thing]
        ) -> [Int: (points: Int, basis: String)] {
            lexicalCalls.bump()
            return reached.filter { id, _ in candidates.contains { $0.id == id } }
        }

        func evidence(
            for candidate: Thing,
            standing: ArbitrationStanding,
            lexical: (points: Int, basis: String)?,
            semantic: Int
        ) -> Evidence {
            Evidence(
                lexical: lexical?.points ?? 0,
                semantic: semantic,
                structure: standing == .candidate ? -10 : 0)
        }

        func rankVector(_ evidence: Evidence, hasGoal: Bool) -> [Int] {
            hasGoal
                ? [evidence.lexical, evidence.semantic, evidence.structure]
                : [evidence.structure]
        }

        var semanticTermIndex: Int? { 1 }
        var tieMargin: Int { 40 }

        func clearsFloor(_ evidence: Evidence, standing: ArbitrationStanding) -> Bool {
            evidence.lexical > 0 || evidence.semantic >= floor
        }

        func sentence(
            for candidate: Thing, evidence: Evidence,
            disposition: ArbitrationDisposition, hasGoal: Bool
        ) -> String {
            switch disposition {
            case .selected: return hasGoal ? "answers best" : "is the first answer"
            case .belowFloor: return "nothing about it answers"
            default: return "something else answered better"
            }
        }

        func note(for candidate: Thing) -> String? { candidate.note }
        func fallsBackWithNoGoal(_ candidates: [Thing]) -> Bool { allowsFallback }
    }

    /// Shared mutable count, because the domain is a value.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - Every candidate is decided

    /// NOT A FILTERED LIST. "Why wasn't it offered" is the question an
    /// arbitration exists to answer, and a candidate missing from the trace is
    /// one nobody can ask about.
    @Test func everyCandidateGetsADecisionAndASentence() {
        let things = [
            Thing(id: 1, label: "reachable"),
            Thing(id: 2, label: "unreachable", standing: .ineligible("has no name")),
            Thing(id: 3, label: "wrong sort", standing: .mismatched("isn't one of those")),
        ]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact")]), goal: "reachable", candidates: things)

        #expect(result.trace.decisions.count == 3)
        #expect(result.trace.decisions.allSatisfy { !$0.reason.isEmpty })
        #expect(result.winner?.id == 1)
        let byID = Dictionary(
            uniqueKeysWithValues: result.trace.decisions.map { ($0.id, $0) })
        #expect(byID[1]?.disposition == .selected)
        #expect(byID[2]?.disposition == .ineligible)
        #expect(byID[2]?.reason == "has no name")
        // A MISMATCH IS ITS OWN SENTENCE, not a generic miss.
        #expect(byID[3]?.reason == "isn't one of those")
    }

    /// THE DECISIONS COME BACK IN THE DOMAIN'S OWN ORDER, whatever order the
    /// ranking put them in — a trace is a record of the page, not of the sort.
    @Test func theTraceKeepsThePresentationOrder() {
        let things = (1...4).map { Thing(id: $0, label: "thing \($0)") }
        let result = Arbitration.run(
            Domain(reached: [3: (400, "exact"), 1: (200, "words")]),
            goal: "thing", candidates: things)
        #expect(result.trace.decisions.map(\.id) == [1, 2, 3, 4])
        #expect(result.winner?.id == 3)
    }

    /// THE NAMING LADDER RUNS ONCE, over what is left after the gate — not once
    /// per candidate, and not over candidates the gate already refused.
    @Test func theNamingLadderRunsOncePerArbitration() {
        let counter = Counter()
        let things = (1...5).map { Thing(id: $0, label: "thing \($0)") }
        _ = Arbitration.run(
            Domain(reached: [1: (400, "exact")], lexicalCalls: counter),
            goal: "thing", candidates: things)
        #expect(counter.value == 1)
    }

    // MARK: - Compared in order, never summed

    /// A PILE OF SMALL PRIORS MUST NOT OUTWEIGH THE STRONGEST TERM. Summing is
    /// what let a navigation strip beat a real result: it carried a little of
    /// several things while the answer carried a lot of one.
    @Test func aStrongerFirstTermWinsWhateverTheRestSay() {
        let things = [
            Thing(id: 1, label: "named exactly"),
            Thing(id: 2, label: "everything else"),
        ]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact"), 2: (300, "contained")]),
            goal: "x", candidates: things,
            // Candidate 2 wins meaning outright and would win a SUM by miles.
            semantic: [1: 0, 2: 900])
        #expect(result.winner?.id == 1)
        let two = result.trace.decisions.first { $0.id == 2 }
        #expect(two?.disposition == .outranked)
        #expect(two?.selectedAlternative == 1)
        // …and the total says the sum would have gone the other way.
        #expect((two?.evidence.total ?? 0) > 400)
    }

    // MARK: - The floor

    /// NOTHING ABOUT IT ANSWERS. A candidate that clears no floor is refused
    /// with the reason, not silently dropped.
    @Test func aCandidateBelowTheFloorIsRefusedWithASentence() {
        let things = [Thing(id: 1, label: "a"), Thing(id: 2, label: "b")]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact")]), goal: "a", candidates: things,
            semantic: [2: 40])
        let two = result.trace.decisions.first { $0.id == 2 }
        #expect(two?.disposition == .belowFloor)
        #expect(two?.reason == "nothing about it answers")
    }

    /// WITH NO GOAL THERE IS NOTHING TO CLEAR. A no-pick arbitration ranks on
    /// what the world says and admits everything the gate did.
    @Test func withNoGoalTheFloorDoesNotApply() {
        let things = [
            Thing(id: 1, label: "plain"),
            Thing(id: 2, label: "unsure", standing: .candidate),
        ]
        let result = Arbitration.run(Domain(), goal: "", candidates: things)
        #expect(result.winner?.id == 1, "the unsure one is ranked down, not the leader")
        #expect(result.trace.decisions.allSatisfy { $0.disposition != .belowFloor })
    }

    // MARK: - A tie is a question

    /// TWO THE EVIDENCE CANNOT SEPARATE STAY TWO, named back rather than guessed
    /// between.
    @Test func anExactTieIsAQuestion() {
        let things = [Thing(id: 1, label: "one"), Thing(id: 2, label: "two")]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact"), 2: (400, "exact")]),
            goal: "x", candidates: things)
        #expect(result.winner == nil)
        #expect(result.rivals.map(\.id) == [1, 2])
        #expect(result.trace.rivals.count == 2)
        #expect(result.trace.selected.isEmpty)
    }

    /// AND SO IS A NEAR-TIE ON MEANING — two similarities a hair apart are noise,
    /// not a verdict.
    @Test func aNearTieOnMeaningIsAlsoAQuestion() {
        let things = [Thing(id: 1, label: "one"), Thing(id: 2, label: "two")]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact"), 2: (400, "exact")]),
            goal: "x", candidates: things,
            semantic: [1: 548, 2: 544])   // four thousandths apart, measured
        #expect(result.winner == nil)
        #expect(result.rivals.count == 2)
    }

    /// BUT A REAL GAP IS A DECISION. The margin separates noise from a verdict;
    /// outside it, meaning decides.
    @Test func aGapWiderThanTheMarginDecides() {
        let things = [Thing(id: 1, label: "one"), Thing(id: 2, label: "two")]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact"), 2: (400, "exact")]),
            goal: "x", candidates: things,
            semantic: [1: 500, 2: 600])
        #expect(result.winner?.id == 2)
    }

    /// A TIE WITH NO GOAL IS NOT A QUESTION — nobody named anything, so there is
    /// nothing to ask about, and the domain's own order answers.
    @Test func aTieWithNoGoalIsNotAQuestion() {
        let things = [Thing(id: 1, label: "one"), Thing(id: 2, label: "two")]
        let result = Arbitration.run(Domain(), goal: "", candidates: things)
        #expect(result.winner?.id == 1)
        #expect(result.rivals.isEmpty)
    }

    // MARK: - Reaching nothing

    /// A GOAL THAT REACHED NOTHING SAYS SO, and every candidate still carries the
    /// sentence explaining why it was not the one.
    @Test func aGoalThatReachesNothingIsRefused() {
        let things = [Thing(id: 1, label: "a"), Thing(id: 2, label: "b")]
        let result = Arbitration.run(Domain(), goal: "something else", candidates: things)
        #expect(result.winner == nil)
        #expect(result.reachedNothing)
        #expect(result.trace.decisions.count == 2)
    }

    /// …UNLESS THE DOMAIN HAS A FIRST ANSWER OF ITS OWN. "Open the first one" is
    /// a real request; refusing to choose is worse than the top result — and the
    /// fallback SAYS it did not match rather than passing it off as one.
    @Test func aDomainWithAFallbackAnswersAndSaysItDidNotMatch() {
        let things = [Thing(id: 1, label: "a"), Thing(id: 2, label: "b")]
        let result = Arbitration.run(
            Domain(allowsFallback: true), goal: "nothing like this", candidates: things)
        #expect(result.winner?.id == 1)
        #expect(result.trace.goalUnmatched)
        // The goal the person said is what the trace reports, not the empty retry.
        #expect(result.trace.goal == "nothing like this")
    }

    /// AND A FALLBACK NEEDS SOMETHING STANDING. With every candidate refused by
    /// the gate there is no first answer to fall back to.
    @Test func aFallbackWithNothingStandingStillRefuses() {
        let things = [
            Thing(id: 1, label: "a", standing: .ineligible("no")),
            Thing(id: 2, label: "b", standing: .ineligible("no")),
        ]
        let result = Arbitration.run(
            Domain(allowsFallback: true), goal: "anything", candidates: things)
        #expect(result.winner == nil)
        #expect(result.reachedNothing)
    }

    // MARK: - What the world said

    /// A NOTE BEATS "SOMETHING ELSE WON". A candidate demoted for being promoted,
    /// or for sitting behind a dialog, is owed the fact rather than the outcome.
    @Test func aDomainsNoteIsSpokenInsteadOfTheOutcome() {
        let things = [
            Thing(id: 1, label: "winner"),
            Thing(id: 2, label: "loser", note: "is marked as promoted"),
        ]
        let result = Arbitration.run(
            Domain(reached: [1: (400, "exact"), 2: (200, "words")]),
            goal: "x", candidates: things)
        let two = result.trace.decisions.first { $0.id == 2 }
        #expect(two?.reason == "is marked as promoted")
    }

    /// THE SAME CANDIDATES IN ANY ORDER REACH THE SAME ANSWER. Presentation order
    /// breaks ties and nothing else.
    @Test func theAnswerDoesNotDependOnPresentationOrder() {
        let reached = [1: (points: 400, basis: "exact"), 2: (points: 200, basis: "words")]
        let forward = Arbitration.run(
            Domain(reached: reached), goal: "x",
            candidates: [Thing(id: 1, label: "one"), Thing(id: 2, label: "two")])
        let backward = Arbitration.run(
            Domain(reached: reached), goal: "x",
            candidates: [Thing(id: 2, label: "two"), Thing(id: 1, label: "one")])
        #expect(forward.winner?.id == backward.winner?.id)
        #expect(forward.winner?.id == 1)
    }

    /// AN EMPTY FIELD IS NOT A CRASH. Nothing to arbitrate is a refusal.
    @Test func noCandidatesIsARefusal() {
        let result = Arbitration.run(Domain(), goal: "x", candidates: [])
        #expect(result.winner == nil)
        #expect(result.reachedNothing)
        #expect(result.trace.decisions.isEmpty)
    }
}
