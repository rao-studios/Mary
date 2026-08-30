//
//  LiveWorkWorld.swift
//  MaryBrain
//
//  WHAT: Where the live work came from — stated by the arbiter, never inferred.
//  IN:   WorkspaceFocusArbiter
//  OUT:  prompt lead / voice place-claim
//  PIN:  Absence is a case, not an Optional (no silent nil default).
//
import Foundation
import MaryAmbient

/// The place that produced this turn's live-work block, as the arbiter
/// resolved it.
public enum LiveWorkWorld: Sendable, Equatable {
    /// An application owns the turn, carrying the display name the user would use for it ("Chrome", "TextEdit").
    case application(String?)
    /// A LIVE DOCUMENT is open and Mary is reading it — named, and saying whether she holds the WHOLE of it or a window onto part of it.
    case document(name: String?, whole: Bool)
    /// NOTHING LEADS. No place contributed live work this turn — Mary may still hold facts and read passages, but she has no place to claim and must claim none.
    case unled

    /// Prompt claim from the turn's machine state. Empty snapshot → unled.
    public init(machine world: AmbientWorld?) {
        guard let world else {
            self = .unled
            return
        }
        let name = world.place.displayName
        if world.isDirectReference {
            self = .document(name: name, whole: false)
        } else if world.place.isApplication {
            self = .application(name)
        } else {
            self = .unled
        }
    }

    /// Arbiter claim, unless it is unled while the turn World already names a place.
    public static func claim(arbiter: LiveWorkWorld, machine: AmbientWorld?) -> LiveWorkWorld {
        if case .unled = arbiter {
            return LiveWorkWorld(machine: machine)
        }
        return arbiter
    }

    /// Bridge from the pin vocabulary.
    public init(_ pinned: PinnedWorld) {
        self = .application(
            AmbientApplicationIndexProvider.current
                .registration(id: pinned.applicationID)?.displayName)
    }
}
