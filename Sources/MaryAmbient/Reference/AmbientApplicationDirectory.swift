//
//  AmbientApplicationDirectory.swift
//  MaryBrain
//
//  BUNDLE ID → HUMAN NAME, session-scoped.
//
//  Generic-application realms carry the BUNDLE ID as their identity (stable,
//  exactly matchable by `clearLead(ifApplication:)` and app-termination) —
//  but a chip reading "led: com.apple.Notes" would be machine truth worn as
//  UI. The localizedName is in hand at the two places activations are
//  observed; it lands here, and `AmbientRealm.displayName` reads it back.
//  Bounded by the number of distinct apps a session touches, like the
//  evidence ledger.
//

import Foundation
import os

public final class AmbientApplicationDirectory: @unchecked Sendable {

    public static let shared = AmbientApplicationDirectory()

    private let box = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public init() {}

    public func note(bundleID: String, name: String?) {
        guard let name, !name.isEmpty else { return }
        box.withLock { $0[bundleID] = name }
    }

    public func name(for bundleID: String) -> String? {
        box.withLock { $0[bundleID] }
    }

    /// App terminated — the identity may be reused by a different version
    /// next launch; the name re-records on the next activation anyway.
    public func evict(bundleID: String) {
        box.withLock { $0[bundleID] = nil }
    }
}
