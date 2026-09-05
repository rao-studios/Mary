//
//  PageRouteTrace.swift
//  MaryPlugin
//
//  WHAT: One page routing decision per row, with the evidence behind it.
//  IN:   PageRouter.arbitrate
//  OUT:  BrowserEngineEvent.routed, BrowserEngineSnapshot.lastRoute, Sand's route pane
//  PIN:  THE ABILITY ROSTER'S SHAPE, ON A PAGE. `AbilityRosterTrace` gives every Skill a
//        disposition, a bounded evidence score and one sentence saying why — never a
//        filtered list, because "why wasn't it offered" is the question a router has to
//        be able to answer. A page needs exactly that and had none of it: three ladders
//        that returned a row or nil, and a phrase that reached nothing left no record of
//        what it was weighed against.
//        IDENTITIES, BOUNDED INTS, ONE SENTENCE. A row's ordinal and its shortened label,
//        never its frame, its address or the page's text. This travels into a debugger
//        and a probe's stdout, so it carries nothing a transcript should not hold.
//        A REASON IS NOT A DEBUG STRING. It is what the pane prints and what a person
//        reads to learn the lane's rules, so it says what was true of the ROW, in the
//        same voice as the arbitrator's ("is behind the dialog", not "structure -200").
//

import Foundation

/// What the goal is FOR — which rows can serve it, and how they are ranked.
public enum PageRouteVerb: Sendable, Equatable {
    /// Press it: a button, a link, a result.
    case press
    /// Type into it.
    case fill
    /// Set it to a position.
    case adjust
    /// Bring it into view. Anything named will do — reveal changes nothing.
    case reveal
    /// Open one of a results page's answers. The query is EVIDENCE, never spoken: it is
    /// what tells a title from the box it was typed into.
    case openResult(query: String)

    /// The word the trace prints.
    public var word: String {
        switch self {
        case .press: return "press"
        case .fill: return "fill"
        case .adjust: return "adjust"
        case .reveal: return "reveal"
        case .openResult: return "result"
        }
    }

    /// The affordance a row must offer to serve this verb outright.
    var wantedAffordance: SeenAffordance? {
        switch self {
        case .press, .openResult: return .press
        case .fill: return .fill
        case .adjust: return .adjust
        case .reveal: return nil
        }
    }
}

/// What became of one row.
public enum PageRouteDisposition: String, Sendable, Equatable, Codable, CaseIterable {
    /// The one row this goal reaches.
    case selected
    /// Cannot serve this verb at all — the gate's answer, before any ranking.
    case ineligible
    /// Eligible, but nothing about it answers the goal.
    case belowFloor
    /// Answered, and something answered better.
    case outranked
    /// Answered exactly as well as another row. A tie is a question, not a coin flip.
    case clarificationRequired
}

/// Which rung of the naming ladder reached this row.
public enum PageRouteLexicalBasis: String, Sendable, Equatable, Codable, CaseIterable {
    case none
    /// "the third video" — a position the person spoke.
    case ordinal
    case exact
    case contained
    /// Every spoken word appears in this label.
    case allWords
    /// The phrase named only a kind, and this row is of it.
    case kindOnly
}

/// The bounded facts that decided one row.
///
/// PIN: `total` IS FOR READING, NOT FOR RANKING. It is the one number a pane can put in a
/// column; the ranking compares the terms in an order that depends on the verb (see
/// `PageRouter.rankVector`), because a naming hit must never be outweighed by a pile of
/// structural priors — the exact mistake that pressed a navigation strip.
public struct PageRouteEvidence: Sendable, Equatable, Codable {
    public var lexical: Int
    public var lexicalBasis: PageRouteLexicalBasis
    /// Cosine against the goal, ×1000. Zero when nothing vectorized.
    public var semantic: Int
    /// How well the row's affordance fits the verb.
    public var affordance: Int
    /// How sure the reading is of this row's name and of its affordance.
    public var provenance: Int
    /// What the row's place on the page says. Signed: a dialog demotes what is behind it.
    public var structure: Int

    public init(
        lexical: Int = 0,
        lexicalBasis: PageRouteLexicalBasis = .none,
        semantic: Int = 0,
        affordance: Int = 0,
        provenance: Int = 0,
        structure: Int = 0
    ) {
        self.lexical = lexical
        self.lexicalBasis = lexicalBasis
        self.semantic = semantic
        self.affordance = affordance
        self.provenance = provenance
        self.structure = structure
    }

    /// The one-number column. Sum of the terms; see the PIN.
    public var total: Int { lexical + semantic + affordance + provenance + structure }
}

/// One row, and what the router made of it.
public struct PageRouteDecision: Sendable, Equatable, Codable, Identifiable {
    /// The row's ordinal in the reading — the number the listing spoke.
    public var ordinal: Int
    /// Shortened; a page's labels run to paragraphs.
    public var label: String
    /// "video", "link", "field", or "text" when the reading named no kind.
    public var kind: String
    public var disposition: PageRouteDisposition
    public var evidence: PageRouteEvidence
    /// For an outranked row: which ordinal won instead.
    public var selectedAlternative: Int?
    public var reason: String

    public var id: Int { ordinal }

    public init(
        ordinal: Int,
        label: String,
        kind: String,
        disposition: PageRouteDisposition,
        evidence: PageRouteEvidence,
        selectedAlternative: Int? = nil,
        reason: String
    ) {
        self.ordinal = ordinal
        self.label = label
        self.kind = kind
        self.disposition = disposition
        self.evidence = evidence
        self.selectedAlternative = selectedAlternative
        self.reason = reason
    }
}

/// The whole verdict for one goal against one read.
public struct PageRouteTrace: Sendable, Equatable, Codable {
    public var goal: String
    public var verb: String
    /// EVERY row the read produced, in ordinal order. A row missing from here is a row
    /// the router never saw, which is a different fault from a row it turned down.
    public var decisions: [PageRouteDecision]
    /// The goal named something and nothing answered to it, so the verb fell back to what
    /// it would have done with no goal at all. Said out loud rather than passed off as a
    /// match.
    public var goalUnmatched: Bool

    public init(
        goal: String = "",
        verb: String = "",
        decisions: [PageRouteDecision] = [],
        goalUnmatched: Bool = false
    ) {
        self.goal = goal
        self.verb = verb
        self.decisions = decisions
        self.goalUnmatched = goalUnmatched
    }

    public static let empty = PageRouteTrace()

    public var selected: [PageRouteDecision] {
        decisions.filter { $0.disposition == .selected }
    }

    public var rivals: [PageRouteDecision] {
        decisions.filter { $0.disposition == .clarificationRequired }
    }

    /// How many rows were still standing when ranking began.
    public var eligibleCount: Int {
        decisions.filter { $0.disposition != .ineligible }.count
    }
}

/// What the router hands back: the row, or the sentence saying why not, and the record.
public struct PageRouteArbitration: Sendable {
    public var winner: AXScreenElement?
    public var refusal: BrowserRefusal?
    public var trace: PageRouteTrace

    public init(
        winner: AXScreenElement? = nil,
        refusal: BrowserRefusal? = nil,
        trace: PageRouteTrace
    ) {
        self.winner = winner
        self.refusal = refusal
        self.trace = trace
    }
}
