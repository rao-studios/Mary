//
//  WindowApplicationResolverTests.swift
//  MaryPluginTests
//
//  WHAT: Which running process a name or bundle identifier means.
//  OUT:  NSWorkspaceApplicationResolver.resolve
//  PIN:  A BUNDLE IDENTIFIER MATCHES EXACTLY. Safari's AutoFill helpers share
//        its prefix, so a partial match on `com.apple.Safari` called the launch
//        ambiguous and nothing opened. Measured, with Safari closed.
//

import Foundation
import Testing
@testable import MaryPlugin

@Suite struct WindowApplicationResolverTests {

    /// What was running with Safari closed: AutoFill extensions, one process
    /// each, all under one helper bundle.
    private let helpers = (1...3).map {
        ManagedApplication(
            bundleIdentifier: "com.apple.SafariPlatformSupport.Helper",
            displayName: "AutoFill (Extension \($0))",
            processIdentifier: pid_t(100 + $0))
    }
    private let chrome = ManagedApplication(
        bundleIdentifier: "com.google.Chrome",
        displayName: "Google Chrome",
        processIdentifier: 200)
    /// Named after Chrome, so "chrome" alone reaches it too.
    private let chromeAutoFill = ManagedApplication(
        bundleIdentifier: "com.apple.SafariPlatformSupport.Helper",
        displayName: "AutoFill (Google Chrome)",
        processIdentifier: 201)

    /// THE COLD LAUNCH THAT NEVER RAN. Not running is the answer that lets
    /// `activateApplication` go on to launch; ambiguous returned before it.
    @Test func aClosedApplicationIsNotRunningRatherThanAmbiguous() {
        let result = NSWorkspaceApplicationResolver.resolve(
            "com.apple.Safari", candidates: helpers, exactOnly: true)
        guard case .failure(.applicationNotRunning) = result else {
            Issue.record("expected not running, got \(result)")
            return
        }
    }

    /// The partial tier is unchanged for a name — which is exactly why an
    /// installed expertise is launched by its bundle and never by its name.
    @Test func withoutExactOnlyThePrefixStillReachesTheHelpers() {
        let result = NSWorkspaceApplicationResolver.resolve(
            "com.apple.Safari", candidates: helpers)
        guard case .failure(.ambiguousApplication) = result else {
            Issue.record("expected the partial tier to reach the helpers, got \(result)")
            return
        }
    }

    @Test func aBundleIdentifierFindsItsProcessBesideAnExtensionNamedLikeIt() {
        let result = NSWorkspaceApplicationResolver.resolve(
            "com.google.Chrome",
            candidates: [chrome, chromeAutoFill] + helpers,
            exactOnly: true)
        guard case .success(let found) = result else {
            Issue.record("expected Chrome, got \(result)")
            return
        }
        #expect(found.processIdentifier == 200)
    }
}
