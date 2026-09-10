//
//  AmbientSelectionTurnSnapshot.swift
//  MaryAmbient
//
//  WHAT: The immutable selection bound to one brain turn, and its task-local.
//  IN:   runTurn, which freezes the packet before any classifier runs
//  OUT:  AmbientContextStore.selectionHandoff / snapshotSelectionForTurn
//  PIN:  They ship together: an EMPTY snapshot means "no selection this turn",
//        a NIL task-local means "not inside a turn at all".
//

import Foundation


/// The immutable selection snapshot bound to one brain turn. A task-local scope
/// deliberately distinguishes "this turn began with no selection" from "this code is not
/// running inside a turn." Without that distinction, a highlight that arrives.
public struct AmbientSelectionTurnSnapshot: Sendable, Equatable {
    public let handoff: AmbientSelectionHandoff?

    public init(handoff: AmbientSelectionHandoff?) {
        self.handoff = handoff
    }

    /// An explicit scoped absence. This is intentionally distinct from an absent TaskLocal
    /// value: the latter means "not running inside a frozen turn" and lets readers consult the
    /// process-wide pending handoff.
    public static let empty = AmbientSelectionTurnSnapshot(handoff: nil)
}

/// Turn-local selection identity. Claiming a handoff removes it from global
/// ambient state, so only code running inside this scope sees that exact
/// highlight. A genuinely new source selection may then arm the next turn.
public enum AmbientSelectionTurnContext {
    @TaskLocal public static var snapshot: AmbientSelectionTurnSnapshot?
}
