//
//  AmbientVoiceDelivery.swift
//  MaryFoundation
//
//  WHAT: Whether a volunteered line reached the ear. Second half of an AmbientVoice row.
//  IN:   MaryAmbient books the candidate; MaryVoice/VoicePipeline writes this late.
//  OUT:  trace pane, rate limiter (`reachedEar`).
//  PIN:  Separate from the engine's emit verdict so scorer vs quiet-room stay distinct.
//

import Foundation

/// Written late onto a candidate the engine booked earlier.
public enum AmbientVoiceDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    /// Reached the ear.
    case spoke
    /// Room busy; waiting for a pause.
    case heldForQuiet
    /// Budget expired still busy. Drop — a late unprompted line is a non-sequitur.
    case droppedStale
    /// User took the floor. Ambient always yields; one negative signal.
    case preemptedByUser
    /// `observe` mode dry run.
    case silencedByMode
    /// Engine decided; no sentence (no model / empty compose). Not `droppedStale`.
    case couldNotCompose
    /// Voice session went idle underneath it.
    case sessionEnded

    public var displayName: String {
        switch self {
        case .spoke:           return "spoke"
        case .heldForQuiet:    return "held for quiet"
        case .droppedStale:    return "dropped — the moment passed"
        case .preemptedByUser: return "you took the floor"
        case .silencedByMode:  return "silenced — observing"
        case .couldNotCompose: return "no voice to say it with"
        case .sessionEnded:    return "session ended"
        }
    }

    /// Reached the ear. One name so pane / report / rate limiter agree (`ReadRoute.reachedVoice`).
    public var reachedEar: Bool { self == .spoke }
}
