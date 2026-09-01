//
//  AmbientSense.swift
//  MaryAmbient
//
//  WHAT: A kind of awareness — what an observer can supply, and how this turn's
//        world was evidenced. One vocabulary for both.
//  OUT:  MaryObserver.ambientSenses / AmbientWorld.Snapshot.sense
//  PIN:  OPEN AND UNRANKED. Senses support interactions, and through them skills;
//        new ones arrive as cases here, never as a parallel enum.
//

import MaryFoundation
import Foundation

public enum AmbientSense: String, CaseIterable, Hashable, Sendable, Codable {
    /// The active application and its workspace state.
    case workspace
    /// A source-owned highlight — the user's own statement of what they mean.
    case selection
    /// Pointer dwell. No producer yet; the vocabulary declares it.
    case hover

    public var displayName: String {
        switch self {
        case .workspace: return "active application"
        case .selection: return "selection"
        case .hover: return "hover"
        }
    }

    /// Default freshness. A caller holding better knowledge — a handoff, a fact —
    /// passes its own window instead.
    public var freshFor: TimeInterval {
        switch self {
        case .workspace: return 15
        case .selection: return AmbientSelectionHandoff.handoffFreshFor
        case .hover: return 3
        }
    }

    /// The perception schema a provider of this sense supplies.
    public var perception: PerceptionID? {
        switch self {
        case .workspace: return .workspaceFocus
        case .hover: return .hover
        case .selection: return nil
        }
    }

    /// The interaction schema a provider of this sense supplies.
    public var interaction: InteractionID? {
        switch self {
        case .selection: return .textSelection
        case .workspace, .hover: return nil
        }
    }
}
