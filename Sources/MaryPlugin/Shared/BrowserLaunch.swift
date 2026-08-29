//
//  BrowserLaunch.swift
//  MaryPlugin
//
//  OPENING A BROWSER — the rung below the bottom of the resolution ladder.
//
//  `BrowserTargetResolver` answers "which of the browsers that are running",
//  and every rung of it presumes one is. When none is, the honest answer used
//  to be the end of the road: "No browser I know is running." For a verb that
//  acts on the page the user is looking at, that is still exactly right —
//  there is no page, and launching a browser to read one nobody opened is a
//  different request than the one that was made.
//
//  BUT A DESTINATION VERB IS NOT THAT. "Go to that video", "put this shader on
//  screen" — these name somewhere to BE, and refusing them because the tool
//  they need is closed is the software equivalent of a shop being shut during
//  opening hours. So `open_location` and `compose_in_web_canvas` opt in, and
//  nothing else does. The opt-in is a parameter rather than a global, because
//  the day it becomes ambient is the day `read_page` starts opening browsers.
//
//  REUSE BEFORE LAUNCH, ALWAYS. This runs only after the whole ladder has
//  answered nothing, which means no declared browser is running at all. A
//  machine with a browser open never reaches here, and a turn that already
//  pinned one never reaches here either.
//
//  ONLY A BROWSER SOME PACKAGE DECLARED. The bundle id comes from a
//  `browserSurface` registration, never from a table in this file and never
//  from a guess at what the machine has. Launching something Mary has no
//  declaration for would open an application she then cannot drive — a
//  failure that costs the user a window and teaches them nothing.
//
//  NO APPLE EVENTS. `NSWorkspace.openApplication` asks the launch services to
//  start a process; it sends no script and issues no command. `VerifiedActivation`'s
//  standing rule — "Mary sends no Apple Events at all" — is untouched.
//
//  A LAUNCH IS NOT A WINDOW, and this is the part that looks like padding and
//  is not. An application can be running, regular, and frontmost with nothing
//  on screen: launch services returns as soon as the process is up, which is
//  well before the first window exists. A chord posted into that gap goes
//  nowhere and reports success. So the launch is not finished until a window
//  is visible.
//

import AppKit
import Foundation

public enum BrowserLaunch {

    /// One declared browser, reduced to what the decision needs. A minimal
    /// descriptor rather than the registration itself, so the policy below is
    /// testable without building a package graph.
    public struct Declared: Sendable, Equatable {
        public var bundleIdentifiers: [String]
        public var displayName: String

        public init(bundleIdentifiers: [String], displayName: String) {
            self.bundleIdentifiers = bundleIdentifiers
            self.displayName = displayName
        }

        /// The id to launch. The FIRST declared, by convention: a package
        /// lists the release build first and its channel variants after, and
        /// launching the Canary because it sorted earlier would be a surprise.
        var primaryBundleID: String? { bundleIdentifiers.first }
    }

    /// What to do, decided before anything is opened.
    public enum Plan: Sendable, Equatable {
        case launch(bundleID: String, displayName: String)
        case stand(Reason)
    }

    /// Why nothing is being launched. Carried rather than collapsed to `nil`
    /// because the caller's sentence differs for each, and reconstructing the
    /// reason from an absence is guesswork.
    public enum Reason: String, Sendable, Equatable {
        /// A browser is running; the ladder simply could not choose between
        /// two. Launching a third would be an odd answer to "which one?".
        case alreadyRunning
        /// Nothing running, more than one declared, and nothing said which.
        case ambiguous
        /// No package declares a browser at all.
        case nothingDeclared
        /// The user named a browser no package declares.
        case namedNotDeclared
    }

    // MARK: - The policy

    /// Which browser to open, given what is declared and what is running.
    ///
    /// PURE, and deliberately so: every rule here is a rule about two sets,
    /// and testing it through `NSWorkspace` would test the launch services.
    ///
    /// - Parameters:
    ///   - named: a browser the user named, if any.
    ///   - declared: every browser some package declared.
    ///   - runningBundleIDs: bundle ids of browsers already up — prefix-matched
    ///     against declarations, like every other browser question here, so a
    ///     Canary or Technology Preview counts as its release build.
    public static func plan(
        named: String?,
        declared: [Declared],
        runningBundleIDs: [String]
    ) -> Plan {
        guard !declared.isEmpty else { return .stand(.nothingDeclared) }

        func isRunning(_ browser: Declared) -> Bool {
            runningBundleIDs.contains { running in
                browser.bundleIdentifiers.contains { declared in
                    running.lowercased().hasPrefix(declared.lowercased())
                }
            }
        }

        // A NAME OUTRANKS EVERYTHING, exactly as it does in the ladder — and
        // it is the one case where launching is unambiguous no matter how
        // many browsers are installed. "Open it in Safari" with Safari closed
        // is a request to open Safari.
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            guard let match = declared.first(where: {
                $0.displayName.lowercased() == wanted
            }) else { return .stand(.namedNotDeclared) }
            guard !isRunning(match) else { return .stand(.alreadyRunning) }
            guard let bundleID = match.primaryBundleID else {
                return .stand(.nothingDeclared)
            }
            return .launch(bundleID: bundleID, displayName: match.displayName)
        }

        // ANY BROWSER RUNNING MEANS THIS IS THE WRONG QUESTION. The ladder
        // answered nothing because it could not CHOOSE, not because there was
        // nothing to choose from, and the caller's refusal already names the
        // rivals and asks.
        guard !declared.contains(where: isRunning) else { return .stand(.alreadyRunning) }

        // NOTHING RUNNING. One declared browser is the only thing Mary could
        // possibly mean; two is a coin toss, and the same rule that governs
        // the ladder governs here — picking is right half the time and is
        // never questioned.
        guard declared.count == 1, let bundleID = declared[0].primaryBundleID else {
            return .stand(.ambiguous)
        }
        return .launch(bundleID: bundleID, displayName: declared[0].displayName)
    }

    // MARK: - The launch

    /// Open it, and do not return until it has a window.
    ///
    /// Returns the process, or nil if it never came up — the caller's existing
    /// refusal is the right sentence for that, because a browser that would
    /// not start is indistinguishable, from here, from one that is not there.
    @discardableResult
    public static func launch(
        bundleID: String,
        displayName: String,
        timeout: TimeInterval = defaultTimeout
    ) async -> BrowserTarget? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }

        let configuration = NSWorkspace.OpenConfiguration()
        // ACTIVATES, because everything a destination verb does next is a
        // chord or a click, and both land in whatever is in front.
        configuration.activates = true
        guard (try? await NSWorkspace.shared.openApplication(
            at: url, configuration: configuration)) != nil
        else { return nil }

        return await awaitWindow(bundleID: bundleID, displayName: displayName, timeout: timeout)
    }

    /// Poll until the launched application is regular AND has a window on a
    /// screen. See the header: the process exists well before the window does.
    static func awaitWindow(
        bundleID: String,
        displayName: String,
        timeout: TimeInterval
    ) async -> BrowserTarget? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return nil }
            let candidate = BrowserTargetResolver.runningBrowsers().first { candidate in
                candidate.isRegularApplication
                    && candidate.bundleID.lowercased().hasPrefix(bundleID.lowercased())
                    && candidate.hasVisibleWindow
            }
            if let candidate {
                return BrowserTarget(
                    bundleID: candidate.bundleID,
                    processIdentifier: candidate.processIdentifier,
                    displayName: displayName)
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        } while Date() < deadline
        return nil
    }

    /// A cold browser start on a loaded machine. Long enough for a first
    /// launch after a restore, short enough that a wedged one does not own
    /// the turn.
    public static let defaultTimeout: TimeInterval = 8
}
