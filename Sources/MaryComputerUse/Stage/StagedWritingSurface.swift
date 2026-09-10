//
//  StagedWritingSurface.swift
//  MaryComputerUse
//
//  WHAT: Lease the keyboard for a write. Focus must not move mid-sentence.
//  OUT:  TyperPlugin | KeyChordPress

import Foundation
import os

public final class StagedWritingSurface: @unchecked Sendable {

    public static let shared = StagedWritingSurface()

    public struct Staged: Sendable, Equatable {
        public let bundleID: String
        public let spokenName: String?
        public let stagedAt: Date

        public init(bundleID: String, spokenName: String?, stagedAt: Date) {
            self.bundleID = bundleID
            self.spokenName = spokenName
            self.stagedAt = stagedAt
        }
    }

    /// Long enough to survive the model's next round in the same turn (and a
    /// short spoken follow-up), short enough that a document staged a minute
    /// ago no longer speaks for where prose belongs.
    public static let freshnessWindow: TimeInterval = 30

    private let box = OSAllocatedUnfairLock<Staged?>(initialState: nil)

    public init() {}

    /// Record a PROVEN staging. Callers verify fronting/creation first — see
    /// the header contract.
    public func record(bundleID: String, spokenName: String? = nil, at date: Date = Date()) {
        box.withLock { $0 = Staged(bundleID: bundleID, spokenName: spokenName, stagedAt: date) }
    }

    /// The staged surface, only while fresh. Non-consuming — resolution may
    /// be retried; the successful typing run consumes.
    public func fresh(at now: Date = Date()) -> Staged? {
        box.withLock { staged in
            guard let staged, now.timeIntervalSince(staged.stagedAt) <= Self.freshnessWindow
            else { return nil }
            return staged
        }
    }

    /// The typing run that landed in the staged app clears the hint — the
    /// destination was delivered, it must not steer a later unrelated write.
    public func consume(bundleID: String) {
        box.withLock { staged in
            if staged?.bundleID == bundleID { staged = nil }
        }
    }

    public func clear() {
        box.withLock { $0 = nil }
    }
}
