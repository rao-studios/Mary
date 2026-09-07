//
//  BrowserAXReadiness.swift
//  MaryComputerUse
//
//  WHAT: Can this application's web content be read through Accessibility yet?
//  IN:   pid + bundle id
//  OUT:  PagePerceptionPipeline's accessibility lane; the probes
//  PIN:  THE STABLE FRONT DOOR, so no caller has to know which attribute a host
//        implements. Idempotent, and quick when the tree already answers.
//        `notNeeded` IS AN ANSWER, NOT A FAILURE. WebKit's tree is always up and
//        an application with no web-content evidence has nothing to wake, so a
//        caller reads `notNeeded` as "walk it" — the same as `ready` — and only
//        `axTreeAbsent` as "the page itself is not exposed".
//

import ApplicationServices
import Foundation

public enum BrowserAXReadiness {

    public enum Readiness: String, Sendable, Equatable {
        /// A web area answered — a walk will see the page.
        case ready
        /// The signals were sent and no web area appeared before the deadline.
        case axTreeAbsent
        /// Nothing to enable: WebKit, whose tree is always on, or an
        /// application with no web-content evidence at all.
        case notNeeded

        /// Whether a walk is worth making. Two of the three rungs say yes.
        public var walkable: Bool { self != .axTreeAbsent }
    }

    /// Sized to the measurement in `WebAXWakeup`: the tree appeared 2.3s after
    /// the request, so three seconds was margin-free and a busy machine would
    /// have reported a page unreachable that was merely still building.
    public static let defaultSettleTimeout: TimeInterval = 6.0

    /// The budget a LIVE READ may spend. A page read already costs the user a
    /// visible pause; six more seconds waiting for a tree that may never come
    /// is worse than falling back to pixels, which always answer.
    public static let readSettleTimeout: TimeInterval = 3.0

    @discardableResult
    public static func ensureWebContentAX(
        pid: pid_t,
        bundleID: String?,
        timeout: TimeInterval = defaultSettleTimeout
    ) async -> Readiness {
        let kind = WebContentHost.classify(pid: pid, bundleID: bundleID)
        guard WebAXWakeup.needsWake(kind) else { return .notNeeded }
        return await WebAXWakeup.ensure(pid: pid, timeout: timeout)
    }
}
