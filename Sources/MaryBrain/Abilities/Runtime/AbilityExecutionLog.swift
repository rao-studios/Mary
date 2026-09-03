//
//  AbilityExecutionLog.swift
//  MaryBrain
//
//  WHAT: Session execution ledger — every real dispatch, exactly once.
//  IN:   dispatch chokepoint (BehavioralAction)
//  OUT:  in-memory ring; Ability-lane Totem is durable
//  PIN:  Stores the behavioral record, not a parallel row type.
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

    /// APPEND, don't insert. Every dispatch lands here, and inserting at the
    /// front shifted the whole 200-record buffer under the lock to maintain an
    /// order only `entries()` cares about. Oldest-first in storage, trimmed in
    /// batches; the reader still sees newest first.
    public func record(_ record: BehavioralActionRecord) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(record)
        if buffer.count > capacity * 2 {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// Newest first.
    public func entries() -> [BehavioralActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.suffix(capacity).reversed()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
