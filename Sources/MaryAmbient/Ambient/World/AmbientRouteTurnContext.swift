//
//  AmbientRouteTurnContext.swift
//  MaryAmbient
//
//  WHAT: The per-turn route holder — a mutable-once box plus its task-local.
//  IN:   runTurn installs the state; runTurnBody notes the route into it.
//  OUT:  AmbientContextStore.route() and every in-turn reader of this turn's route
//  PIN:  Nil state = not in a turn. Never fall back to another turn's route;
//        only the store's process-global box may do that.
//

import Foundation
import os

/// Mutable-once route holder after classifiers run inside a frozen turn.
/// PIN: TaskLocal cannot be reassigned; this box can. Caller: runTurnBody.
public final class AmbientRouteTurnState: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock<AmbientRoute?>(initialState: nil)

    public init() {}

    public func note(_ route: AmbientRoute) { box.withLock { $0 = route } }
    public func current() -> AmbientRoute? { box.withLock { $0 } }
}

/// Per-request route holder. Nil = this turn has not routed yet.
/// PIN: never fall back to another turn's process-global snapshot.
public enum AmbientRouteTurnContext {
    @TaskLocal public static var state: AmbientRouteTurnState?
}
