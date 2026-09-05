//
//  Arbitration.swift
//  MaryAmbient
//
//  WHAT: One goal, many candidates, one winner — and a sentence for every loser.
//  IN:   a domain that says what its candidates are and what counts as evidence
//  OUT:  ArbitrationResult — the winner, or the refusal, and the whole record
//  PIN:  THE PROCEDURE, NOT THE DOMAIN. Mary decides which Skill an utterance
//        earns by scoring every candidate against typed evidence, admitting on a
//        floor, ranking on a vector and giving every loser a disposition and a
//        sentence. A page needed exactly that and grew its own copy — same
//        shape, same vocabulary, nothing shared — so the two could drift and
//        neither could be read against the other. This is that procedure, once.
//        PURE, AND THAT IS WHAT MAKES IT TESTABLE. No world, no clock, no
//        await: a function of the candidates and the goal it was handed.
//        EVERY CANDIDATE GETS A DECISION. Not a filtered list — "why wasn't it
//        offered" is the question a router exists to answer, and a candidate
//        missing from the trace is one nobody can ask about.
//        COMPARED IN ORDER, NEVER SUMMED. A rank vector is compared term by
//        term, so no pile of small priors can outweigh the strongest evidence
//        there is. Summing is what let a navigation strip beat a real result: it
//        carried a little of several things while the answer carried a lot of one.
//        A TIE IS A QUESTION. Two candidates the evidence cannot separate stay
//        two, named back to the person — unless the domain says its fallback
//        answers better than a refusal would.
//

import Foundation

/// Whether a candidate may serve this goal at all, and on what terms.
public enum ArbitrationStanding: Sendable, Equatable {
    /// The reading says this candidate does exactly what the goal needs.
    case offered
    /// Admitted, and held to more — the reading is not sure of it.
    case candidate
    case ineligible(String)
    /// Real and reachable, just not of the sort this goal needs. Kept apart from
    /// `ineligible` because NAMING A REAL THING OF THE WRONG SORT IS A DIFFERENT
    /// MISTAKE FROM NAMING NOTHING, and it earns the sentence that says which.
    case mismatched(String)

    public var admits: Bool {
        switch self {
        case .offered, .candidate: return true
        case .ineligible, .mismatched: return false
        }
    }

    public var reason: String? {
        switch self {
        case .offered, .candidate: return nil
        case .ineligible(let reason), .mismatched(let reason): return reason
        }
    }
}

/// What became of one candidate.
public enum ArbitrationDisposition: String, Sendable, Equatable, Codable, CaseIterable {
    /// The one candidate this goal reaches.
    case selected
    /// Cannot serve this goal at all — the gate's answer, before any ranking.
    case ineligible
    /// Eligible, but nothing about it answers the goal.
    case belowFloor
    /// Answered, and something answered better.
    case outranked
    /// Answered exactly as well as another. A tie is a question, not a coin flip.
    case clarificationRequired
}

/// The bounded facts one domain scores with.
///
/// PIN: `total` IS FOR READING, NOT FOR RANKING. It is the one number a pane can
/// put in a column; the ranking compares the terms in an order the domain
/// chooses, because a naming hit must never be outweighed by a pile of priors.
public protocol ArbitrationEvidence: Sendable, Equatable, Codable {
    static var empty: Self { get }
    var total: Int { get }
}

/// One candidate, and what the arbitration made of it.
public struct ArbitrationDecision<
    ID: Hashable & Sendable & Codable, Evidence: ArbitrationEvidence
>: Sendable, Equatable, Codable, Identifiable {
    public var id: ID
    /// Shortened for reading; never the candidate's whole content.
    public var label: String
    /// What sort of thing it is, in the domain's own word.
    public var kind: String
    public var disposition: ArbitrationDisposition
    public var evidence: Evidence
    /// For an outranked candidate: which one won instead.
    public var selectedAlternative: ID?
    public var reason: String

    public init(
        id: ID,
        label: String,
        kind: String,
        disposition: ArbitrationDisposition,
        evidence: Evidence,
        selectedAlternative: ID? = nil,
        reason: String
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.disposition = disposition
        self.evidence = evidence
        self.selectedAlternative = selectedAlternative
        self.reason = reason
    }
}

/// The whole verdict for one goal.
public struct ArbitrationTrace<
    ID: Hashable & Sendable & Codable, Evidence: ArbitrationEvidence
>: Sendable, Equatable, Codable {
    public var goal: String
    /// What the goal was FOR, in the domain's own word.
    public var verb: String
    /// EVERY candidate, in the order the domain presented them. One missing is a
    /// candidate the arbitration never saw, which is a different fault from one
    /// it turned down.
    public var decisions: [ArbitrationDecision<ID, Evidence>]
    /// The goal named something and nothing answered to it, so the verb fell
    /// back to what it would have done with no goal at all. Said out loud rather
    /// than passed off as a match.
    public var goalUnmatched: Bool

    public init(
        goal: String = "",
        verb: String = "",
        decisions: [ArbitrationDecision<ID, Evidence>] = [],
        goalUnmatched: Bool = false
    ) {
        self.goal = goal
        self.verb = verb
        self.decisions = decisions
        self.goalUnmatched = goalUnmatched
    }

    public var selected: [ArbitrationDecision<ID, Evidence>] {
        decisions.filter { $0.disposition == .selected }
    }

    public var rivals: [ArbitrationDecision<ID, Evidence>] {
        decisions.filter { $0.disposition == .clarificationRequired }
    }

    /// How many candidates were still standing when ranking began.
    public var eligibleCount: Int {
        decisions.filter { $0.disposition != .ineligible }.count
    }
}

/// What one domain must answer for its candidates to be arbitrated.
public protocol ArbitrationDomain {
    associatedtype Candidate: Sendable
    associatedtype ID: Hashable & Sendable & Codable
    associatedtype Evidence: ArbitrationEvidence

    func identity(of candidate: Candidate) -> ID
    /// Shortened for the trace — never the candidate's whole content.
    func label(of candidate: Candidate) -> String
    func kindWord(of candidate: Candidate) -> String

    /// May this candidate serve the goal at all, and on what terms.
    /// PIN: ABOUT THE CANDIDATE, NOT THE GOAL. Whether a slider can be pressed
    /// is true before anyone says anything; whether it is the slider they meant
    /// is the ranking's question. Keeping them apart is what lets a trace say
    /// "isn't a button" for one and "something else answered better" for the
    /// next, instead of one undifferentiated miss.
    func standing(of candidate: Candidate) -> ArbitrationStanding

    /// The naming ladder, run ONCE over everything still standing: which
    /// candidates the words reached, how strongly, and by which rung.
    func lexical(
        goal: String, among candidates: [Candidate]
    ) -> [ID: (points: Int, basis: String)]

    func evidence(
        for candidate: Candidate,
        standing: ArbitrationStanding,
        lexical: (points: Int, basis: String)?,
        semantic: Int
    ) -> Evidence

    /// The order the terms are compared in. Descending, term by term.
    func rankVector(_ evidence: Evidence, hasGoal: Bool) -> [Int]

    /// Which slot of the rank vector carries MEANING, whose ties are noise
    /// rather than a verdict. Nil when no term is a similarity.
    var semanticTermIndex: Int? { get }
    /// How close two meanings must be before the difference is noise.
    var tieMargin: Int { get }

    func clearsFloor(_ evidence: Evidence, standing: ArbitrationStanding) -> Bool

    /// One sentence, in the arbitrator's voice, completing "…" after the name.
    func sentence(
        for candidate: Candidate,
        evidence: Evidence,
        disposition: ArbitrationDisposition,
        hasGoal: Bool
    ) -> String

    /// A note the domain wants said instead of "something else won" — what the
    /// world said about this candidate, which is worth more than the outcome.
    func note(for candidate: Candidate) -> String?

    /// With a goal that reached nothing, may the arbitration retry with no goal
    /// at all? "Open the first one" is a real request, and refusing to choose
    /// there can be a worse answer than the domain's own first answer.
    func fallsBackWithNoGoal(_ candidates: [Candidate]) -> Bool
}

public struct ArbitrationResult<Domain: ArbitrationDomain>: Sendable {
    /// The candidate this goal reached.
    public var winner: Domain.Candidate?
    /// The rivals a tie could not separate, when it could not.
    public var rivals: [Domain.Candidate]
    /// Nothing answered, and nothing was named that could.
    public var reachedNothing: Bool
    public var trace: ArbitrationTrace<Domain.ID, Domain.Evidence>

    public init(
        winner: Domain.Candidate? = nil,
        rivals: [Domain.Candidate] = [],
        reachedNothing: Bool = false,
        trace: ArbitrationTrace<Domain.ID, Domain.Evidence>
    ) {
        self.winner = winner
        self.rivals = rivals
        self.reachedNothing = reachedNothing
        self.trace = trace
    }
}

public enum Arbitration {

    /// One goal, one pass, every candidate decided.
    public static func run<Domain: ArbitrationDomain>(
        _ domain: Domain,
        goal rawGoal: String,
        verb: String = "",
        candidates: [Domain.Candidate],
        semantic: [Domain.ID: Int] = [:]
    ) -> ArbitrationResult<Domain> {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGoal = !goal.isEmpty

        // 1 — the gate. Every candidate, one sentence each.
        var standings: [Domain.ID: ArbitrationStanding] = [:]
        var decisions: [Domain.ID: ArbitrationDecision<Domain.ID, Domain.Evidence>] = [:]
        var eligible: [Domain.Candidate] = []
        for candidate in candidates {
            let id = domain.identity(of: candidate)
            let standing = domain.standing(of: candidate)
            standings[id] = standing
            if let reason = standing.reason {
                decisions[id] = decision(
                    domain, candidate, disposition: .ineligible,
                    evidence: .empty, reason: reason)
            } else {
                eligible.append(candidate)
            }
        }

        // 2 — the naming ladder, once, over what is left.
        let lexical = hasGoal ? domain.lexical(goal: goal, among: eligible) : [:]

        // 3 — the evidence, and the floor.
        var ranked: [(candidate: Domain.Candidate, evidence: Domain.Evidence, vector: [Int])] = []
        for candidate in eligible {
            let id = domain.identity(of: candidate)
            let standing = standings[id] ?? .offered
            let evidence = domain.evidence(
                for: candidate, standing: standing,
                lexical: lexical[id], semantic: semantic[id] ?? 0)
            guard !hasGoal || domain.clearsFloor(evidence, standing: standing) else {
                decisions[id] = decision(
                    domain, candidate, disposition: .belowFloor, evidence: evidence,
                    reason: domain.note(for: candidate)
                        ?? domain.sentence(
                            for: candidate, evidence: evidence,
                            disposition: .belowFloor, hasGoal: hasGoal))
                continue
            }
            ranked.append((
                candidate, evidence, domain.rankVector(evidence, hasGoal: hasGoal)))
        }

        // 4 — the verdict.
        guard !ranked.isEmpty else {
            // A GOAL THAT REACHED NOTHING IS NOT ALWAYS A DEAD END. Where the
            // domain has a first answer of its own and something was standing,
            // saying so beats reporting a full page as empty.
            if hasGoal, domain.fallsBackWithNoGoal(candidates),
               candidates.contains(where: {
                   standings[domain.identity(of: $0)]?.admits ?? false
               }) {
                var retry = run(
                    domain, goal: "", verb: verb,
                    candidates: candidates, semantic: semantic)
                retry.trace.goal = goal
                retry.trace.goalUnmatched = true
                return retry
            }
            return ArbitrationResult(
                reachedNothing: true,
                trace: finish(domain, goal: goal, verb: verb,
                              decisions: decisions, candidates: candidates))
        }

        ranked.sort { ranksBefore(($0.vector, order(domain, $0.candidate, candidates)),
                                  ($1.vector, order(domain, $1.candidate, candidates))) }
        let best = ranked[0].vector
        // A GENUINE TIE IS STILL A TIE, and two similarities a hair apart are not
        // a decision: separating them would be reading noise as evidence.
        let winners = ranked.filter { entry in
            guard entry.vector.count == best.count else { return false }
            for (index, value) in entry.vector.enumerated() where value != best[index] {
                guard hasGoal, index == domain.semanticTermIndex,
                      abs(best[index] - value) <= domain.tieMargin
                else { return false }
            }
            return true
        }
        // A tie with NO goal is not a question — the domain's own order answers
        // it, because refusing to choose is worse than its first answer.
        let tied = winners.count > 1 && hasGoal
        let winningIDs = Set(winners.map { domain.identity(of: $0.candidate) })
        let leaderID = domain.identity(of: ranked[0].candidate)
        for entry in ranked {
            let id = domain.identity(of: entry.candidate)
            if tied, winningIDs.contains(id) {
                decisions[id] = decision(
                    domain, entry.candidate, disposition: .clarificationRequired,
                    evidence: entry.evidence,
                    reason: "answers to \"\(goal)\" as well as \(winners.count - 1) other"
                        + (winners.count == 2 ? "" : "s"))
            } else if id == leaderID {
                decisions[id] = decision(
                    domain, entry.candidate, disposition: .selected,
                    evidence: entry.evidence,
                    reason: domain.sentence(
                        for: entry.candidate, evidence: entry.evidence,
                        disposition: .selected, hasGoal: hasGoal))
            } else {
                decisions[id] = decision(
                    domain, entry.candidate, disposition: .outranked,
                    evidence: entry.evidence,
                    selectedAlternative: leaderID,
                    // WHAT THE WORLD SAID ABOUT IT beats "something else won": a
                    // candidate demoted for being promoted, or for sitting behind
                    // a dialog, is owed the fact rather than the outcome.
                    reason: domain.note(for: entry.candidate)
                        ?? domain.sentence(
                            for: entry.candidate, evidence: entry.evidence,
                            disposition: .outranked, hasGoal: hasGoal))
            }
        }

        let trace = finish(
            domain, goal: goal, verb: verb, decisions: decisions, candidates: candidates)
        if tied {
            return ArbitrationResult(
                rivals: winners.map(\.candidate), trace: trace)
        }
        return ArbitrationResult(winner: ranked[0].candidate, trace: trace)
    }

    // MARK: - The pieces

    private static func decision<Domain: ArbitrationDomain>(
        _ domain: Domain,
        _ candidate: Domain.Candidate,
        disposition: ArbitrationDisposition,
        evidence: Domain.Evidence,
        selectedAlternative: Domain.ID? = nil,
        reason: String
    ) -> ArbitrationDecision<Domain.ID, Domain.Evidence> {
        ArbitrationDecision(
            id: domain.identity(of: candidate),
            label: domain.label(of: candidate),
            kind: domain.kindWord(of: candidate),
            disposition: disposition,
            evidence: evidence,
            selectedAlternative: selectedAlternative,
            reason: reason)
    }

    /// Decisions in the domain's own order, and never one short of the
    /// candidates it was handed.
    private static func finish<Domain: ArbitrationDomain>(
        _ domain: Domain,
        goal: String,
        verb: String,
        decisions: [Domain.ID: ArbitrationDecision<Domain.ID, Domain.Evidence>],
        candidates: [Domain.Candidate]
    ) -> ArbitrationTrace<Domain.ID, Domain.Evidence> {
        ArbitrationTrace(
            goal: goal, verb: verb,
            decisions: candidates.compactMap { decisions[domain.identity(of: $0)] })
    }

    /// The candidate's place in the domain's own presentation — the last word in
    /// a comparison, so two candidates nothing can separate are still ordered
    /// the same way on every run.
    private static func order<Domain: ArbitrationDomain>(
        _ domain: Domain, _ candidate: Domain.Candidate, _ candidates: [Domain.Candidate]
    ) -> Int {
        let id = domain.identity(of: candidate)
        return candidates.firstIndex { domain.identity(of: $0) == id } ?? candidates.count
    }

    /// Lexicographic, descending, with presentation order as the tiebreak.
    static func ranksBefore(
        _ lhs: (vector: [Int], order: Int), _ rhs: (vector: [Int], order: Int)
    ) -> Bool {
        for (left, right) in zip(lhs.vector, rhs.vector) where left != right {
            return left > right
        }
        return lhs.order < rhs.order
    }
}
