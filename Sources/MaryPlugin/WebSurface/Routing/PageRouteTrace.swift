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
///
/// PIN: THE ARBITRATION'S OWN VOCABULARY, not a second copy of it. These were
/// hand-written twins of `ArbitrationDisposition`, `ArbitrationDecision` and
/// `ArbitrationTrace` — same cases, same fields, same meanings — which is what
/// let the page's answers and the roster's stop being comparable.
public typealias PageRouteDisposition = ArbitrationDisposition
public typealias PageRouteDecision = ArbitrationDecision<Int, PageRouteEvidence>
public typealias PageRouteTrace = ArbitrationTrace<Int, PageRouteEvidence>

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
/// PIN: `total` IS FOR READING, NOT FOR RANKING. It is the one number a pane can
/// put in a column; the ranking compares the terms in an order that depends on
/// the verb (see `PageRouter.rankVector`), because a naming hit must never be
/// outweighed by a pile of structural priors — the exact mistake that pressed a
/// navigation strip.
public struct PageRouteEvidence: ArbitrationEvidence {
    public var lexical: Int
    public var lexicalBasis: PageRouteLexicalBasis
    /// Cosine against the goal, ×1000. Zero when nothing vectorized.
    public var semantic: Int
    /// How well the row's affordance fits the verb.
    public var affordance: Int
    /// How sure the reading is of this row's name and of its affordance.
    public var provenance: Int
    /// What the row's place on the page says. Signed: a dialog demotes what is
    /// behind it.
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

    public static var empty: PageRouteEvidence { PageRouteEvidence() }
}

/// What the router hands back: the row, or the sentence saying why not, and the record.
public struct PageRouteArbitration: Sendable {
    /// The row this goal reached.
    public var winner: PageRow?
    public var refusal: BrowserRefusal?
    public var trace: PageRouteTrace

    public init(
        winner: PageRow? = nil,
        refusal: BrowserRefusal? = nil,
        trace: PageRouteTrace
    ) {
        self.winner = winner
        self.refusal = refusal
        self.trace = trace
    }
}
