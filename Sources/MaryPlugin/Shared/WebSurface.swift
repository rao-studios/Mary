//
//  WebSurface.swift
//  MaryPlugin
//
//  DRIVING A WEB PAGE WITH NO SCRIPT OF ANY KIND — eyes and hands, the way a
//  person does it.
//
//  The predecessor promised no JavaScript and kept it, while still leaning on
//  each browser's scripting dictionary for the things Accessibility looked
//  unlikely to give: a new tab, the tab's title, the page's text, the address.
//  Mary sends no Apple Events at all (see `VerifiedActivation`'s NO SECOND
//  ROAD), so every one of those had to be asked again from the AX side. The
//  answers were better than the road they replace, and each is recorded at
//  the method that rides it.
//
//  MACHINE CAPABILITY, NOT ONE ABILITY'S PRIVATE CODE — which is why it sits
//  in Shared/ beside `StageArbiter` and `VerifiedActivation` rather than
//  inside whichever lane calls it first. "Open a page, find the editable
//  region, put text in it, press a chord, read the page back" is a capability;
//  what to type and why is a package's business. Nothing here knows what a
//  shader is, or what any site is.
//
//  ENGINE-NEUTRAL BY CONSTRUCTION. There is no browser named in this file and
//  no engine enum to switch on. Everything is pid-parameterized and reads
//  what the tree in front of it says — which is what lets one implementation
//  serve WebKit and Chromium, and what makes a third browser a package rather
//  than a code change. Where the two engines genuinely differ (a tab's name
//  lives in a description in one and a title in the other) the difference is
//  a LADDER climbed at read time, not a branch.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryFoundation

public enum WebSurface {

    /// Bounded search. A loaded page is a big tree and an unbounded walk is a
    /// stall waiting to happen; the chrome-only searches get a much smaller
    /// budget again, because the toolbar is shallow and a walk that reaches
    /// the page from there has already gone wrong.
    static let pageBudget = AXTreeWalker.Budget(maxDepth: 24, maxNodes: 4000)
    static let chromeBudget = AXTreeWalker.Budget(maxDepth: 12, maxNodes: 400)

    /// Why a run could not proceed. Each case is a sentence Mary can say
    /// truthfully; none of them is "something went wrong".
    ///
    /// EVERY CASE IS ENGINE-NEUTRAL, and the browser's name arrives at
    /// speaking time. The predecessor's equivalent carried Safari in the case
    /// names and grew a `spoken(browser:)` to work around it, which meant a
    /// Chrome failure could still say "Safari" wherever a caller forgot.
    public enum Failure: Error, Equatable, Sendable {
        case notRunning
        case couldNotOpenTab
        case couldNotReachAddressBar
        case neverLoaded
        case humanCheck
        case blockedByDialog(String)
        case notFrontmost(String)
        case noEditableSurface
        case couldNotFocus
        case placingTextFailed
        case stageBusy
        case cancelled
        /// The browser has not exposed the page to Accessibility. Distinct
        /// from `noEditableSurface`: the PAGE is invisible, not merely
        /// editor-less — and distinct from `neverLoaded`, because a page that
        /// arrived and was never published is a different remedy.
        case pageNotExposed

        public func spoken(browser: String) -> String {
            switch self {
            case .notRunning:
                return "\(browser) isn't running, so I couldn't open the page."
            case .couldNotOpenTab:
                return "\(browser) wouldn't open a new tab."
            case .couldNotReachAddressBar:
                return "I couldn't find \(browser)'s address bar, so I didn't navigate."
            case .neverLoaded:
                return "The page never finished loading."
            case .humanCheck:
                return """
                The site is asking me to prove I'm human, and that check needs \
                you — clear it once in \(browser) and ask me again.
                """
            case .blockedByDialog(let title):
                return "\(browser) is showing a dialog I shouldn't answer for you — \(title)."
            case .notFrontmost(let front):
                return "I couldn't bring \(browser) forward; \(front) kept the screen."
            case .noEditableSurface:
                return "I couldn't find the editor on the page."
            case .couldNotFocus:
                return "I found the editor but couldn't put the caret in it."
            case .placingTextFailed:
                return "I couldn't hand the text to the page."
            case .stageBusy:
                return "Something else was using the screen, so I left it alone."
            case .cancelled:
                return "The browser action was interrupted, so I stopped."
            case .pageNotExposed:
                return """
                \(browser) hasn't exposed the page to Accessibility yet — I \
                asked it to; give it a beat and ask again.
                """
            }
        }
    }

    // MARK: - Handles

    /// AX handle for one browser process, with a messaging timeout so a
    /// wedged renderer cannot park the turn on a synchronous read.
    public static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 3.0)
        return element
    }

    public static func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        AX.element(application, kAXFocusedWindowAttribute)
            ?? AX.element(application, kAXMainWindowAttribute)
    }

    /// The front window's title. What the predecessor asked the scripting
    /// dictionary for, and the only signal either browser gives for WHICH tab
    /// is current — Safari does not publish `AXSelected` on its tabs.
    public static func windowTitle(pid: pid_t) -> String? {
        focusedWindow(in: application(pid: pid))
            .flatMap { AX.string($0, kAXTitleAttribute) }
    }

    // MARK: - The page

    /// Which web area a multi-frame page yields. A page with nested iframes
    /// publishes several; a code editor's is usually the first breadth-first,
    /// while a document editor's is the LARGEST.
    public enum WebAreaStrategy: Sendable {
        case first
        case largest
    }

    public static func webArea(
        in application: AXUIElement, strategy: WebAreaStrategy = .first
    ) -> AXUIElement? {
        guard let window = focusedWindow(in: application) else { return nil }
        return webArea(inWindow: window, strategy: strategy)
    }

    /// Window-rooted sibling, for a caller that has already proved which
    /// window it holds and must not re-read the application's mutable
    /// focused-window attribute midway through an interaction.
    public static func webArea(
        inWindow window: AXUIElement, strategy: WebAreaStrategy = .first
    ) -> AXUIElement? {
        var found: AXUIElement?
        var foundArea: CGFloat = 0
        AXTreeWalker.walk(from: window, budget: pageBudget) { element, _ in
            guard AX.string(element, kAXRoleAttribute) == "AXWebArea" else { return }
            switch strategy {
            case .first:
                if found == nil { found = element }
            case .largest:
                let size = AX.frame(of: element).map { $0.width * $0.height } ?? 0
                if size > foundArea { found = element; foundArea = size }
            }
        }
        return found
    }

    /// The live screen bounds of the rendered page, excluding the browser's
    /// own toolbar and tab strip.
    public static func visiblePageFrame(
        in application: AXUIElement, strategy: WebAreaStrategy = .largest
    ) -> CGRect? {
        webArea(in: application, strategy: strategy).flatMap { AX.frame(of: $0) }
    }
}
