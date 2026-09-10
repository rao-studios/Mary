//
//  WebContentHost.swift
//  MaryComputerUse
//
//  WHAT: What kind of web content sits behind this pid (webkit / chromium / electron / none).
//  OUT:  wake lane skip | AXEngine.ambientContext webContentHost
//  PIN:  Electron = Electron Framework.framework on disk, not an allowlist.
//        Last rung is .none — never "unknown, try anyway."

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

    /// The pure ladder. `containsFramework` answers "does this app's `Contents/Frameworks`
    /// hold a bundle by this name?".
    static func classify(bundleID: String?, containsFramework: (String) -> Bool) -> Kind {
        if let bundleID {
            if webKitBundlePrefixes.contains(where: bundleID.hasPrefix) { return .webkit }
            if chromiumBundlePrefixes.contains(where: bundleID.hasPrefix) { return .chromium }
        }
        if containsFramework(electronFrameworkName) { return .electron }
        if containsFramework(cefFrameworkName) { return .chromium }
        return .none
    }

    /// Classified once per bundle id and remembered — an installed app's frameworks do not
    /// change while it is running, so the disk answer is stable for the session.
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
