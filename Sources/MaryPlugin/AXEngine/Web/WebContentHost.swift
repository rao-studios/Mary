//
//  WebContentHost.swift
//  MaryAdapter
//
//  THE AX ENGINE / WEB SUB-ENGINE — see AXEngine.swift for the directory's
//  doctrine header and Web/WebAXWakeup.swift for the measured wake-up story.
//
//  WHAT KIND OF WEB CONTENT IS BEHIND THIS PID — the one question the rest of
//  the web sub-engine branches on. Three families reach the same AXWebArea
//  through different doors:
//
//    • WebKit (Safari) exposes its web tree unconditionally. Asking it to
//      wake would be harmless and pointless; it answers `.webkit` so the
//      wake lane can skip it and Clyde can say "always on" instead of
//      pretending to wait.
//    • Chromium (Chrome, Arc, Brave, Edge, Vivaldi, Opera — and CEF hosts
//      like Spotify) builds NO web-content AX hierarchy until an assistive
//      client announces itself.
//    • Electron is Chromium wearing a native shell. Same lazy tree, same
//      wake signals, but its bundle id is the APP's (`md.obsidian`), so no
//      browser prefix list will ever name it.
//
//  WHY A FILESYSTEM PROBE AND NOT A LONGER LIST. An allowlist of Electron
//  apps would be a maintenance treadmill that is wrong the first time a user
//  installs something not on it — the same objection that keeps `siteWords`
//  and `PageElementKindDerivation` table-free. An Electron app is
//  MECHANICALLY identifiable: it ships `Electron Framework.framework` inside
//  its own bundle. That is positive, checkable evidence about this exact
//  installed app, and it costs at most two `stat` calls.
//
//  WHY THE LADDER IS CONSERVATIVE AT THE BOTTOM. `AXEnhancedUserInterface` —
//  one of the two signals the wake lane sends — is the flag that makes some
//  AppKit apps re-lay-out their windows (see WebAXWakeup's header). This
//  classifier is what bounds that blast radius, so its last rung is `.none`,
//  never "unknown app, try anyway." An app gets a wake signal only on
//  positive evidence: a seeded browser id, or a framework that is actually
//  on disk inside its bundle.
//
//  Known and accepted: an unseeded Chromium browser (or a WebKit browser
//  that is not Safari) classifies `.none` and is never woken. That is the
//  same gap Chrome-only gating had, shrunk to the long tail rather than
//  closed by guessing — a generic `* Framework.framework` scan was
//  considered and rejected as insufficient evidence.
//

import AppKit
import Foundation
import os

public enum WebContentHost {

    public enum Kind: String, Sendable, Equatable {
        /// WebKit — the AX tree is always on; never send a wake signal.
        case webkit
        /// Chromium browsers and CEF hosts — lazy tree, needs the wake.
        case chromium
        /// An Electron shell — Chromium in native clothing; needs the wake.
        case electron
        /// No web-content evidence. Behaviorally identical to today: nothing
        /// is sent, nothing is waited for.
        case none
    }

    static let electronFrameworkName = "Electron Framework.framework"
    static let cefFrameworkName = "Chromium Embedded Framework.framework"

    /// Seeds, matched by PREFIX so Beta/Dev/Canary/Technology-Preview
    /// variants ride the same rung as their release build.
    static let webKitBundlePrefixes = ["com.apple.Safari"]
    static let chromiumBundlePrefixes = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",  // Arc
    ]

    /// The pure ladder. `containsFramework` answers "does this app's
    /// `Contents/Frameworks` hold a bundle by this name?" — injected so the
    /// whole decision is unit-testable without a filesystem (see
    /// WebContentHostTests), and so the seeded rungs can be PINNED as never
    /// touching the disk at all.
    ///
    /// Order is load-bearing: seeds first means a known browser is answered
    /// from a string compare, and the probe is reached only for apps no seed
    /// names. Electron before CEF because an Electron app carries only the
    /// former, while the two names are distinct enough that the order is a
    /// cost decision, not a correctness one.
    static func classify(bundleID: String?, containsFramework: (String) -> Bool) -> Kind {
        if let bundleID {
            if webKitBundlePrefixes.contains(where: bundleID.hasPrefix) { return .webkit }
            if chromiumBundlePrefixes.contains(where: bundleID.hasPrefix) { return .chromium }
        }
        if containsFramework(electronFrameworkName) { return .electron }
        if containsFramework(cefFrameworkName) { return .chromium }
        return .none
    }

    /// Classified once per bundle id and remembered — an installed app's
    /// frameworks do not change while it is running, so the disk answer is
    /// stable for the session. An app with no bundle id (a bare executable)
    /// skips the cache and is probed by pid each time; there is nothing to
    /// key on and such a process is not a web host in the first place.
    private static let cache = OSAllocatedUnfairLock<[String: Kind]>(initialState: [:])

    public static func classify(pid: pid_t, bundleID: String?) -> Kind {
        if let bundleID, let memo = cache.withLock({ $0[bundleID] }) { return memo }
        let kind = classify(
            bundleID: bundleID,
            containsFramework: { name in
                guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL
                else { return false }
                let candidate = bundleURL
                    .appendingPathComponent("Contents/Frameworks", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                return FileManager.default.fileExists(atPath: candidate.path)
            })
        if let bundleID { cache.withLock { $0[bundleID] = kind } }
        return kind
    }
}
