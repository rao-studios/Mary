//
//  AmbientRankingModels.swift
//  MaryAmbient
//
//  WHAT: AmbientRankingMode and AmbientRendering.
//  IN:   AmbientRanking.swift (split)
//  OUT:  prompt assembly / AmbientInjectionTrace
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

/// What one rendering pass produced.
public struct AmbientRendering: Sendable, Equatable {
    /// Which branch of the user's rule decided the order.
    public var mode: AmbientRankingMode
    /// TIER 0, rendered FIRST and charged to the budget first: the accessibility surface each
    /// lane's details stand on (`AmbientSurface.surfaceLine`).
    public var surfaceLines: [String]
    /// Facts that won the budget, rendered in full, in rank order.
    public var blocks: [String]
    /// Facts that LOST the budget — one line each, with their bounds and
    /// their age. Never silent.
    public var mentions: [String]
    /// The keys behind `blocks` + `mentions`, in the same order, so the pane
    /// and the turn loop can talk about exactly what the prompt rendered.
    public var keys: [AmbientKey]

    public init(
        mode: AmbientRankingMode,
        surfaceLines: [String] = [],
        blocks: [String] = [],
        mentions: [String] = [],
        keys: [AmbientKey] = []
    ) {
        self.mode = mode
        self.surfaceLines = surfaceLines
        self.blocks = blocks
        self.mentions = mentions
        self.keys = keys
    }

    public var isEmpty: Bool {
        surfaceLines.isEmpty && blocks.isEmpty && mentions.isEmpty
    }
}
