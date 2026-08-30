//
//  AmbientIntent.swift
//  MaryAmbient
//
//  WHAT: Resolved shape of one user turn.
//  OUT:  AmbientRoute / prompts and memory. Not which apps or Abilities the user may reach.
//  PIN:  AmbientSignal sits beside the answer so a wrong route is visible in one glance.
//
import Foundation

/// What the user is doing this turn.
public enum AmbientIntent: String, Sendable, Equatable, CaseIterable, Codable {

    /// Explore a design or plan before committing to an action.
    case architect

    /// A bare yes/no answering a parked CONFIRM. Executed with no model in
    /// the loop at all (`MaryBrain.runTurn`'s deterministic decision path).
    case decide

    /// A bare "stop" while routines run — halts everything, deterministically.
    case halt

    /// Change words that already exist: replace a section, cut a paragraph,
    /// move a passage. Needs LOCATE first, and must never reach the caret.
    case revise

    /// Write words that did not exist, at the user's cursor, as they watch.
    case compose

    /// Run something — control the Mac, call a binding, drive an app.
    case operate

    /// A question about what is on screen right now. Deictic, or naming the
    /// world the user is already in.
    case perceive

    /// A question answered by reading something — a named part of a document,
    /// or an eyeless source like the calendar.
    case ask

    /// Small talk, opinions, knowledge. No Skill execution, eyes, or document.
    case converse

    /// Does this shape act on the world, or only talk about it? Used for
    /// reporting only — nothing gates on it.
    public var isActing: Bool {
        switch self {
        case .revise, .compose, .operate, .decide, .halt: return true
        case .architect, .perceive, .ask, .converse: return false
        }
    }

    /// Does this shape concern words already in a document? The turns where
    /// the revision contract (locate → bounded change → report) applies.
    public var touchesExistingProse: Bool { self == .revise }
}

/// WHICH SIGNAL DECIDED, kept beside the answer so a wrong route is debuggable in one
/// glance instead of by re-deriving seven classifiers. `AmbientRankingMode` carries
/// `transformUnfocused` for exactly this reason.
public enum AmbientSignal: String, Sendable, Equatable, CaseIterable, Codable {
    /// An architecture or brainstorming request.
    case architectAbility
    /// A parked action plus a bare yes/no.
    case pendingDecision
    /// A bare "no"/"stop" while routines run.
    case routineStop
    /// `EditIntentClassifier.intent(in:)` returned a shape.
    case editIntent
    /// `ActionClassifier.isActionCommand` said command.
    case actionCommand
    /// An action verb in the writing register with no edit intent.
    case writingRegister
    /// A fresh direct-reference signal, such as the user's current selection.
    case attention
    /// `AmbientRanker.isDeictic` — "this paragraph", "on my screen".
    case deixis
    /// The utterance named the world that leads.
    case namedLeadWorld
    /// `NamedPartClassifier.namedPart` found something to read.
    case namedPart
    /// The utterance names an eyeless source — calendar, reminders, mail.
    case ambientSource
    /// Nothing fired.
    case none
}
