//
//  PendingSkillStore.swift
//  MaryBrain
//
//  WHAT: The one skill invocation awaiting spoken go-ahead.
//  IN:   AbilityRuntime write path
//  OUT:  confirm / cancel replay
//  PIN:  Lock-guarded so AbilityRuntime stays a Sendable class.
//
import Foundation
import os

public struct PendingSkillConfirmation: Sendable {
    public let id: UUID
    public let skillName: String
    /// The already-resolved local implementation. Replaying this value avoids
    /// resolving under a different Ability package revision after approval.
    public let binding: SkillBinding?
    /// Execution context captured with the binding and preview.
    public let context: AbilityExecutionContext
    /// Package identity frozen on the originating turn.
    public let reference: AbilitySkillReference
    /// Post-reconciliation arguments, replayed verbatim on confirmation.
    public let arguments: [String: String]
    public let preview: String
    public let createdAt: Date
    /// Registry turn counter at creation.
    public let turnIndex: Int
    /// Frozen Capability policy and source signals from the originating turn.
    /// Approval replays this exact authorization boundary even if Studio
    /// activates a new package revision before the user says yes.
    let executionPolicy: CapabilityExecutionPolicy
    let signalSnapshot: SchemaSignalTurnSnapshot
}

final class PendingSkillStore: Sendable {

    private struct State {
        var pending: PendingSkillConfirmation?
        var turnIndex: Int = 0
    }

    /// Valid during the creating turn and the next full turn (where the user
    /// says yes/no), never longer than the TTL.
    private let timeToLive: TimeInterval
    private let state: OSAllocatedUnfairLock<State>

    init(timeToLive: TimeInterval = 180) {
        self.timeToLive = timeToLive
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// A new user turn began; expires stale pendings and returns the index.
    @discardableResult
    func beginTurn(now: Date = Date()) -> Int {
        state.withLock { s in
            s.turnIndex += 1
            if let pending = s.pending, isExpired(pending, turnIndex: s.turnIndex, now: now) {
                s.pending = nil
            }
            return s.turnIndex
        }
    }

    /// Replaces any prior pending — the latest confirmable Skill wins.
    func set(
        skillName: String,
        arguments: [String: String],
        preview: String,
        binding: SkillBinding? = nil,
        context: AbilityExecutionContext,
        reference: AbilitySkillReference,
        executionPolicy: CapabilityExecutionPolicy = .unconstrained,
        signalSnapshot: SchemaSignalTurnSnapshot = .empty,
        now: Date = Date()
    ) {
        state.withLock { s in
            s.pending = PendingSkillConfirmation(
                id: UUID(),
                skillName: skillName,
                binding: binding,
                context: context,
                reference: reference,
                arguments: arguments,
                preview: preview,
                createdAt: now,
                turnIndex: s.turnIndex,
                executionPolicy: executionPolicy,
                signalSnapshot: signalSnapshot
            )
        }
    }

    func current(now: Date = Date()) -> PendingSkillConfirmation? {
        state.withLock { s in
            guard let pending = s.pending else { return nil }
            if isExpired(pending, turnIndex: s.turnIndex, now: now) {
                s.pending = nil
                return nil
            }
            return pending
        }
    }

    /// Pop for execution.
    func take(now: Date = Date()) -> PendingSkillConfirmation? {
        state.withLock { s in
            guard let pending = s.pending else { return nil }
            s.pending = nil
            if isExpired(pending, turnIndex: s.turnIndex, now: now) { return nil }
            return pending
        }
    }

    func clear() {
        state.withLock { $0.pending = nil }
    }

    private func isExpired(
        _ pending: PendingSkillConfirmation,
        turnIndex: Int,
        now: Date
    ) -> Bool {
        turnIndex > pending.turnIndex + 1 || now.timeIntervalSince(pending.createdAt) > timeToLive
    }
}
