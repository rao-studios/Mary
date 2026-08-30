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
