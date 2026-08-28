//
//  StagedWritingSurface.swift
//  MaryBrain
//
//  THE JUST-STAGED WRITING DESTINATION — one slot, newest wins.
//
//  The incident this closes: "draft those sections in a fresh Pages document"
//  ran `new_pages_document`, and the follow-up `type_at_cursor` resolved its
//  target from ROUTED ATTENTION — computed at TURN START, before the document
//  existed — so typing chased a stale pre-turn highlight (or refused) while
//  the fresh document sat empty. A binding that deliberately puts a writing
//  surface in front records it here; the typer's resolve ladder consults this
//  slot BEFORE turn-start attention, so create → type lands in the created
//  document mechanically.
//
//  TRUTHFULNESS CONTRACT (the user's direct requirement): record ONLY on
//  PROVEN staging — an app-level op after frontmost verification, a
//  window-level op after focused-window verification, a document create after
//  its own script confirmed the document. An unverified activation must never
//  become typing-destination evidence.
//
//  The slot decays on its own (freshnessWindow) and is consumed by the typing
//  run that lands in it — a hint about "the surface just staged for you",
//  never a standing preference.
//

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
