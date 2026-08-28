//
//  BrowserAXReadiness.swift
//  MaryPlugin
//
//  THE AX ENGINE / WEB SUB-ENGINE — see AXEngine.swift for the directory's
//  doctrine header.
//
//  THE STABLE FRONT DOOR to "can this app's web content be read yet?" Every
//  caller that is about to walk a page asks this first, in one sentence, and
//  gets one of three answers it can act on. The machinery behind it —
//  which hosts are eligible (`Web/WebContentHost.swift`), which signals wake
//  them and what was measured (`Web/WebAXWakeup.swift`) — is deliberately not
//  the caller's problem.
//
//  WHY THE THREE-CASE VERDICT AND NOT A BOOL. `.axTreeAbsent` is the case
//  that earns this file: a page that has not been built yet reads EXACTLY
//  like a page with no content, and a caller that cannot tell them apart
//  reports "I don't see anything on that page" about a page that is simply
//  still waking. `.notNeeded` is a success too — WebKit's tree is always up —
//  so a caller that treats non-`.ready` as failure is wrong in the common
//  case. Match all three.
//
//  Mary ships this without the predecessor's Chrome-only bundle gate: every
//  lazy-tree host reaches the wake lane on `WebContentHost`'s evidence, so a
//  non-Chrome Chromium or an Electron app now attempts a real wake where the
//  older shape returned `.notNeeded` instantly and was then read as an empty
//  page. The cost of that correctness is the settle timeout on a genuine
//  miss.
//

import ApplicationServices
import Foundation

public enum BrowserAXReadiness {

    public enum Readiness: Sendable, Equatable {
        /// A web area answered — walks will see the page.
        case ready
        /// The signals were sent but no web area appeared before the deadline.
        /// Distinct from "no editor on this page": the PAGE itself is not
        /// exposed yet, and saying so is the difference between an honest
        /// "not yet" and a false "nothing there".
        case axTreeAbsent
        /// Nothing to enable — either WebKit, whose tree is always on, or an
        /// app with no web-content evidence at all. A success, not a refusal.
        case notNeeded
    }

    /// Sized to the measurement in `WebAXWakeup`: the tree appeared 2.3s after
    /// the request, so a three-second budget was margin-free and a slow
    /// machine would have reported a page as unreachable that was merely
    /// still building.
    public static let defaultSettleTimeout: TimeInterval = 6.0

    /// Ensure the app behind `pid` exposes web content to Accessibility.
    /// Idempotent, and cheap when the tree already answers.
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
