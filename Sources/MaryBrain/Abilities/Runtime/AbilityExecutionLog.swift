//
//  AbilityExecutionLog.swift
//  MaryBrain
//
//  THE SESSION'S EXECUTION LEDGER — every real dispatch, exactly once.
//
//  IT STORES THE BEHAVIORAL RECORD, not a shape of its own, and that is the
//  whole change. The ledger this replaces had its own row type, composed at
//  its own call sites, alongside a chip composed somewhere else and a receipt
//  composed somewhere else again — up to six disjoint records per action, no
//  two of which had to agree.
//
//  THEY DID NOT AGREE. The log's row took the reference from the STATIC
//  snapshot; the chip took it from the TURN-PATCHED one. Both were right about
//  their own question and they printed different providers for the same act,
//  which is the kind of divergence nobody finds until they are debugging
//  something else at two in the morning. Composing once, at the dispatch
//  chokepoint, makes them the same value rather than two values kept in step
//  by discipline.
//
//  THE KEY-SNIFFING `target(from:)` WENT WITH IT. It guessed what an action
//  acted on by looking for an argument called "document", "file", "path",
//  "title", "query" or eight others — a name-shaped heuristic that got the
//  wrong answer whenever a package used a different word, and had nothing at
//  all to say for a Skill whose target was the thing in front of the user.
//  `BehavioralAction.target` is the element that was ACTUALLY touched, with
//  its frame, read at the moment of the act.
//
//  In-memory and session-scoped by design; Ability-lane Totem is the
//  durable record.
//

import Foundation
import MaryFoundation

/// Lock-boxed ring buffer, newest first. `.shared` is what the app reads;
/// tests inject their own so parallel suites never share state.
public final class AbilityExecutionLog: @unchecked Sendable {

    public static let shared = AbilityExecutionLog()

    private let lock = NSLock()
    private var buffer: [BehavioralActionRecord] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ record: BehavioralActionRecord) {
        lock.lock()
        defer { lock.unlock() }
        buffer.insert(record, at: 0)
        if buffer.count > capacity {
            buffer.removeLast(buffer.count - capacity)
        }
    }

    /// Newest first.
    public func entries() -> [BehavioralActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
