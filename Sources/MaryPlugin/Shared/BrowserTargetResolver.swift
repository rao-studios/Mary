//
//  BrowserTargetResolver.swift
//  MaryPlugin
//
//  WHICH BROWSER, AND WHICH PROCESS OF IT.
//
//  The browser is ONE workspace — `AmbientPlaceResolver`'s carve-out says so,
//  and it is right: a person with Safari and Chrome open is not in two
//  places, they are browsing. But a place cannot be typed into. Somewhere
//  between "the browser workspace" and a keystroke, exactly one process has
//  to be named, and this is where.
//
//  ROSTER IS CAPABILITY, LEDGER IS TARGETING. The place decides what Mary can
//  do; this decides where it lands. Conflating them is how a turn ends up
//  reading Chrome and typing into Safari.
//
//  WHICH BUNDLES COUNT AS BROWSERS is not written here either. It comes from
//  `AmbientPlaceResolver.browserBundlePrefixes`, which reads the installed
//  registrations — so a browser is whatever declared itself one by realizing
//  `browsing`, and adding a third is a package rather than an edit to this
//  file.
//
//  THE HELPER TRAP, which a prefix match alone walks straight into. A browser
//  ships XPC helper processes under its own bundle prefix — a sandbox broker,
//  a platform-support helper. They match `com.apple.Safari` perfectly, they
//  are running, and they have no windows: every AX read against one returns
//  nothing, which is indistinguishable from a browser showing an empty page.
//  `activationPolicy == .regular` is the filter that separates an application
//  from its own plumbing, and it is not optional.
//

import AppKit
import Foundation
import MaryAmbient

/// One browser process, frozen. A bundle id names an application; only a pid
/// names the thing a keystroke will reach.
public struct BrowserTarget: Sendable, Equatable {
    public var bundleID: String
    public var processIdentifier: pid_t
    /// What to call it out loud. From the registration that claimed the
    /// bundle, so a package's own display name is what the user hears.
    public var displayName: String

    public init(bundleID: String, processIdentifier: pid_t, displayName: String) {
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
        self.displayName = displayName
    }

    /// Still there. A pid outlives the process it named, and the next one to
    /// take that number is some other program entirely.
    public var isAlive: Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.isTerminated == false
    }
}

public enum BrowserTargetResolver {

    /// What the ladder sees of each running application — enough to decide,
    /// and nothing that needs AppKit. Injected in tests so the rungs are
    /// exercised without a browser installed.
    public struct Candidate: Sendable, Equatable {
        public var bundleID: String
        public var processIdentifier: pid_t
        public var localizedName: String
        /// False for XPC helpers and agents. See the header — this is the
        /// whole defence against reading a sandbox broker as an empty page.
        public var isRegularApplication: Bool
        public var isFrontmost: Bool
        /// Whether this process currently has a window on a screen. The rung
        /// that saves a turn when two browsers run and only one is visible.
        public var hasVisibleWindow: Bool

        public init(
            bundleID: String,
            processIdentifier: pid_t,
            localizedName: String,
            isRegularApplication: Bool,
            isFrontmost: Bool,
            hasVisibleWindow: Bool
        ) {
            self.bundleID = bundleID
            self.processIdentifier = processIdentifier
            self.localizedName = localizedName
            self.isRegularApplication = isRegularApplication
            self.isFrontmost = isFrontmost
            self.hasVisibleWindow = hasVisibleWindow
        }
    }

    /// Which rung answered. Recorded rather than inferred: when a turn drives
    /// the wrong browser, the useful question is which rule chose it, and
    /// reconstructing that from the outcome is guesswork.
    public enum Decision: String, Sendable, Equatable {
        case named
        case pinned
        case frontmost
        case evidenced
        case soleVisible
        case soleRunning
        case none
    }

    public struct Resolution: Sendable, Equatable {
        public var target: BrowserTarget?
        public var decidedBy: Decision
    }

    // MARK: - The ladder

    /// Resolve, over an injected roster. Pure — every rung is a rule about a
    /// set of candidates, and the live half below is only how the set is
    /// gathered.
    ///
    /// ORDER IS THE WHOLE CONTENT. A NAME the user said outranks everything,
    /// including what is in front of them: "reload it in Safari" while Chrome
    /// is frontmost means Safari, and a ladder that let frontmost win would
    /// be confidently wrong in the one case the user was most explicit. Then
    /// the pin (this turn already chose, and a turn drives one browser), then
    /// what is actually in front of them, then what the ledger saw recently,
    /// then the only one they can see, then the only one running at all.
    public static func resolve(
        named: String? = nil,
        pinned: BrowserTarget? = nil,
        evidencedBundleID: String? = nil,
        among candidates: [Candidate],
        displayName: (String) -> String? = { AmbientPlaceResolver.browserName(bundleID: $0) }
    ) -> Resolution {
        let browsers = candidates.filter(\.isRegularApplication)

        func target(_ candidate: Candidate) -> BrowserTarget {
            BrowserTarget(
                bundleID: candidate.bundleID,
                processIdentifier: candidate.processIdentifier,
                displayName: displayName(candidate.bundleID) ?? candidate.localizedName)
        }

        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            // Matched on the name the USER would say — a registration's
            // display name or the running application's own — never a bundle
            // id, which is not a word anybody speaks.
            if let hit = browsers.first(where: { candidate in
                let display = (displayName(candidate.bundleID) ?? candidate.localizedName)
                    .lowercased()
                return display == wanted || candidate.localizedName.lowercased() == wanted
            }) {
                return Resolution(target: target(hit), decidedBy: .named)
            }
            // A NAME THAT MATCHES NOTHING STOPS THE LADDER. Falling through
            // to frontmost would silently drive a different browser than the
            // one the user named, which is worse than doing nothing.
            return Resolution(target: nil, decidedBy: .none)
        }

        if let pinned, browsers.contains(where: {
            $0.processIdentifier == pinned.processIdentifier
        }) {
            return Resolution(target: pinned, decidedBy: .pinned)
        }

        if let front = browsers.first(where: \.isFrontmost) {
            return Resolution(target: target(front), decidedBy: .frontmost)
        }

        if let evidencedBundleID,
           let hit = browsers.first(where: { $0.bundleID.hasPrefix(evidencedBundleID) }) {
            return Resolution(target: target(hit), decidedBy: .evidenced)
        }

        let visible = browsers.filter(\.hasVisibleWindow)
        if visible.count == 1 {
            return Resolution(target: target(visible[0]), decidedBy: .soleVisible)
        }
        if browsers.count == 1 {
            return Resolution(target: target(browsers[0]), decidedBy: .soleRunning)
        }
        // TWO BROWSERS AND NO REASON TO PREFER EITHER IS NOT A COIN TOSS.
        // Answering nothing lets the caller say which two it saw; picking one
        // gets it right half the time and is never questioned.
        return Resolution(target: nil, decidedBy: .none)
    }

    // MARK: - The live roster

    /// Every running browser, as the ladder wants to see it.
    public static func runningBrowsers(
        prefixes: [String] = AmbientPlaceResolver.browserBundlePrefixes,
        visibleBundleIDs: Set<String>? = nil
    ) -> [Candidate] {
        guard !prefixes.isEmpty else { return [] }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let visible = visibleBundleIDs ?? onScreenBundleIDs()

        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundleID = application.bundleIdentifier,
                  prefixes.contains(where: bundleID.hasPrefix)
            else { return nil }
            return Candidate(
                bundleID: bundleID,
                processIdentifier: application.processIdentifier,
                localizedName: application.localizedName ?? bundleID,
                // The helper filter. See the header.
                isRegularApplication: application.activationPolicy == .regular,
                isFrontmost: application.processIdentifier == frontmost,
                hasVisibleWindow: visible.contains(bundleID))
        }
    }

    /// Bundle ids with a window actually on a screen, from the window server
    /// rather than from AX — a minimized or off-Space window is not something
    /// the user can see, and "the only browser in front of me" is a claim
    /// about what is in front of them.
    static func onScreenBundleIDs() -> Set<String> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var pids: Set<pid_t> = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }
            pids.insert(pid)
        }
        return Set(pids.compactMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        })
    }

    /// The live resolve, gathering the roster itself.
    public static func resolve(
        named: String? = nil,
        pinned: BrowserTarget? = nil,
        evidencedBundleID: String? = nil
    ) -> Resolution {
        resolve(
            named: named,
            pinned: pinned,
            evidencedBundleID: evidencedBundleID,
            among: runningBrowsers())
    }
}
