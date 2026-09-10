//
//  AmbientRankingMode.swift
//  MaryAmbient
//
//  WHAT: Which of the three branches decided this turn's fact order.
//  IN:   AmbientRanker's three-way rule
//  OUT:  AmbientRoute.rankingMode — recorded so a trace can say WHY this order
//  PIN:  Diagnostic vocabulary, not a switch: nothing routes on the mode itself.
//

import Foundation

/// Which of the three branches decided this turn's order.
public enum AmbientRankingMode: String, Sendable, Equatable, CaseIterable {
    /// The default: relevance to the current utterance.
    case relevance
    /// The utterance concerns the focused world — its facts lead.
    case focusedWorld
    /// The utterance asks Mary to TRANSFORM a world that is not focused.
    /// Ordering falls back to relevance; the case exists so that fallback is
    /// visible and pinnable rather than indistinguishable from the default.
    case transformUnfocused

    /// The two modes that order by pure relevance.
    public var ordersByRelevance: Bool { self != .focusedWorld }
}
