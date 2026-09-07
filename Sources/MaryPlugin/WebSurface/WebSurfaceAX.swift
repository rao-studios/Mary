//
//  WebSurfaceAX.swift
//  MaryPlugin
//
//  WHAT: The browser's own shell, through Accessibility — tabs, address, history,
//        and WHERE THE PAGE IS.
//  IN:   AXEngine.snapshot / .detail over a declared browser
//  OUT:  Reading — the frame the vision lane then reads pixels from
//  PIN:  AX FOR THE BROWSER, PIXELS FOR THE PAGE. Everything in this file is a control
//        the browser itself draws and publishes properly; nothing here walks into page
//        content, even where a browser exposes it. Safari does expose YouTube's player
//        buttons — measured — and using them would make Safari work and Chrome not,
//        which is the split this design exists to remove.
//        NIL IS A FAILED READ. A `Reading` with `canGoBack == nil` means the button was
//        not found, never that history is empty.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation

public enum WebSurfaceAX {

    /// One look at a browser's shell.
    public struct Reading: Sendable, Equatable {
        /// The page's own title, with the browser's name trimmed off.
        public var title: String?
        /// HELD, NEVER SPOKEN — the browser lane's URL doctrine. Say the site name.
        public var url: String?
        /// The visible page region, in global top-left screen points.
        public var pageFrame: CGRect?
        /// How the frame was worked out, for a probe and for an honest refusal.
        public var pageFrameSource: String
        public var canGoBack: Bool?
        public var canGoForward: Bool?
        /// Tab names in bar order, browser noise removed.
        public var tabs: [String]
        /// The same tabs as the browser labels them — what a press has to name.
        public var tabLabels: [String] = []
        public var activeTabIndex: Int?
        public var windowID: CGWindowID?
        public var windowFrame: CGRect
        /// Whether this browser's page content reaches Accessibility at all today.
        public var pageReachableByAX: Bool
        /// A question the browser itself is asking, standing in front of the page.
        /// Nil is the ordinary state; see `Dialog`.
        public var dialog: Dialog?

        public init(
            title: String? = nil, url: String? = nil, pageFrame: CGRect? = nil,
            pageFrameSource: String = "none", canGoBack: Bool? = nil,
            canGoForward: Bool? = nil, tabs: [String] = [], activeTabIndex: Int? = nil,
            windowID: CGWindowID? = nil, windowFrame: CGRect = .zero,
            pageReachableByAX: Bool = false, dialog: Dialog? = nil
        ) {
            self.title = title
            self.url = url
            self.pageFrame = pageFrame
            self.pageFrameSource = pageFrameSource
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.tabs = tabs
            self.activeTabIndex = activeTabIndex
            self.windowID = windowID
            self.windowFrame = windowFrame
            self.pageReachableByAX = pageReachableByAX
            self.dialog = dialog
        }

        /// The site, as a person would say it. The URL itself never leaves this type.
        public var siteName: String? { url.flatMap(SiteName.spoken(url:)) }
    }

    /// THE BROWSER ASKING SOMETHING OF ITS OWN — a form resubmission, a
    /// "leave this site?", a permission, a script's alert — modal over the
    /// page, so nothing on the page can be read or pressed until it is answered.
    ///
    /// PIN: MEASURED IN CHROME, AND IT IS NOT A WINDOW. "Confirm Form
    /// Resubmission" is published INSIDE the browsing window as an `AXGroup`
    /// with the `AXApplicationDialog` subrole: a heading, a static text and two
    /// buttons ("Cancel", "Continue"), left to right. `browsingWindow` still
    /// finds the page's window, the page's own tree is still there underneath,
    /// and a reload while it is up settled as "Reloaded" — a page nobody could
    /// see. A dialog is a fact of the shell, read where the tabs are read, and
    /// its buttons are shell controls the shell press already reaches.
    ///
    /// NEVER PRESSED ON MARY'S OWN INITIATIVE. The choices are what the person
    /// is told; one of them said back is what answers it.
    public struct Dialog: Sendable, Equatable {
        /// What it is asking, as the browser titles it.
        public var title: String
        /// The longer text under the title, when the browser publishes one.
        public var message: String?
        /// The buttons, as labelled, left to right.
        public var choices: [String]

        public init(title: String, message: String? = nil, choices: [String]) {
            self.title = title
            self.message = message
            self.choices = choices
        }

        /// The browser's words alone: the title, and the body when there is one.
        public var question: String { message.map { "\(title) — \($0)" } ?? title }

        /// The question as Mary asks it back: the browser's words, then the choices.
        public var spoken: String {
            let offered = choices.map { "\"\($0)\"" }
            switch offered.count {
            case 0: return "The browser is asking: \(question)"
            case 1: return "The browser is asking: \(question) It offers \(offered[0])."
            default:
                return "The browser is asking: \(question) "
                    + "\(offered.dropLast().joined(separator: ", ")) or \(offered.last!)?"
            }
        }
    }

    /// The subroles and roles a modal question is published under. Platform
    /// vocabulary — an assistive client's, not any one site's.
    static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXDialog", "AXSystemDialog"]
    static let dialogRoles: Set<String> = ["AXSheet"]
    /// How much of a dialog's body is worth saying.
    static let dialogMessageCap = 240

    /// The dialog standing in `window`, if one is. `nodes` is the window's
    /// flattened tree, so the dialog's subtree is found by walking down from
    /// the node itself rather than by searching again.
    static func dialog(in root: AXNodeSnapshot, pid: pid_t) -> Dialog? {
        var found: AXNodeSnapshot?
        root.forEachNode { node in
            guard found == nil, node.id != root.id else { return }
            if dialogSubroles.contains(node.subrole ?? "") || dialogRoles.contains(node.role) {
                found = node
            }
        }
        guard let found else { return nil }
        return dialog(from: found, message: {
            guard let read = AXEngine.detail(pid: pid, nodeID: found.id, options: .shell)
            else { return nil }
            return read.detail.nodes.values.compactMap(\.textValue)
        })
    }

    /// PURE — the dialog's shape from its subtree, with the body text handed in
    /// so the offline reader needs no live element.
    static func dialog(from node: AXNodeSnapshot, message: () -> [String]?) -> Dialog? {
        var heading: String?
        var buttons: [AXNodeSnapshot] = []
        node.forEachNode { child in
            if child.role == "AXHeading", heading == nil,
               let label = child.label, !label.isEmpty { heading = label }
            if child.role == "AXButton", let label = child.label, !label.isEmpty,
               child.isEnabled { buttons.append(child) }
        }
        let title = [node.label, heading].compactMap { $0 }.first { !$0.isEmpty }
        guard let title else { return nil }
        let choices = buttons
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
            .map { $0.label! }
        var body = (message() ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(title) != .orderedSame }
            .joined(separator: " ")
        if body.count > dialogMessageCap {
            body = String(body.prefix(dialogMessageCap)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return Dialog(title: title, message: body.isEmpty ? nil : body, choices: choices)
    }

    // MARK: - Reading

    /// `preferring` names the window the caller works in — see
    /// `browsingWindow(among:preferring:identify:)`.
    public static func read(
        pid: pid_t, registration: WebSurfaceRegistration, preferring wanted: CGWindowID? = nil
    ) -> Reading? {
        guard AXIsProcessTrusted() else { return nil }
        // THE SHELL PRESET. Every read in this file is about the browser's own
        // window — title, tabs, history, the address field, the page's frame —
        // and once the page's accessibility tree is awake `.exhaustive` walks
        // several thousand page nodes to reach a toolbar. See `Options.shell`.
        guard let snapshot = AXEngine.snapshot(pid: pid, options: .shell),
              let window = browsingWindow(
                  among: snapshot.windows, preferring: wanted, identify: \.windowID),
              let root = window.root
        else { return nil }

        var reading = Reading(
            windowFrame: window.frame ?? .zero,
            pageReachableByAX: registration.host(pid: pid) == .webkit)
        reading.title = registration.pageTitle(fromWindowTitle: window.title)

        var nodes: [AXNodeSnapshot] = []
        root.forEachNode { nodes.append($0) }

        // History buttons: found by the declared label, and their ENABLED state is the
        // answer — a disabled Back is an observation, not a failure.
        if let back = nodes.first(where: { registration.isBackLabel($0.label) }) {
            reading.canGoBack = back.isEnabled
        }
        if let forward = nodes.first(where: { registration.isForwardLabel($0.label) }) {
            reading.canGoForward = forward.isEnabled
        }

        // Tabs, in bar order — left to right, which is how a person counts them.
        if let tabRole = registration.schema.tabRole {
            let tabs = nodes
                .filter { $0.role == tabRole && $0.label?.isEmpty == false }
                .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
            reading.tabs = tabs.map { registration.tabTitle(fromLabel: $0.label ?? "") }
            reading.tabLabels = tabs.map { $0.label ?? "" }
            // The active tab is the one whose name the window wears.
            if let title = reading.title {
                reading.activeTabIndex = reading.tabs.firstIndex {
                    $0.caseInsensitiveCompare(title) == .orderedSame
                }
            }
        }

        let webArea = nodes.first { $0.category == .webArea }
        let (frame, source) = pageFrame(
            window: window.frame,
            toolbars: nodes.filter { $0.role == toolbarRole }.compactMap(\.frame),
            webArea: webArea?.frame,
            source: registration.schema.pageFrameSource)
        reading.pageFrame = frame
        reading.pageFrameSource = source
        // THE ELEMENT'S OWN ID, and the window list's guess only for a
        // snapshot that has none — four windows a round opens all sit at the
        // same origin, and the origin named the wrong one.
        reading.windowID = window.windowID
            ?? windowIdentifier(pid: pid, frame: window.frame, title: window.title)

        reading.url = url(
            pid: pid, nodes: nodes, webArea: webArea, registration: registration,
            window: reading.windowID)
        // THE QUESTION IN FRONT OF THE PAGE, if the browser is asking one.
        reading.dialog = dialog(in: root, pid: pid)
        return reading
    }

    /// The window a page is IN, among everything the browser has open.
    ///
    /// PIN: A PANEL CAN BE THE MAIN WINDOW, AND THEN EVERY READ IS ABOUT THE
    /// PANEL. MEASURED: after `find_in_page`, Chrome's find bar is its own
    /// accessibility window and takes `AXMain` — so the shell reported the page
    /// title as "Find in page", published no tabs, and every later read in the
    /// turn was about a strip forty points tall. A browsing window is the one
    /// with the browser's own furniture in it: a toolbar, or the page itself.
    /// Told apart by SHAPE, never by a title.
    ///
    /// AND THE WINDOW MARY WORKS IN COMES BEFORE THE ONE THE BROWSER CALLS
    /// MAIN. The browser's main window is whichever the person last clicked;
    /// measured in round 9, a session that read "the main window" moved into
    /// the person's own window the moment they touched it, opened tabs there
    /// and played a video in it. `preferring` is the window the caller has
    /// been working in, identified by `identify` (its window-server id); it
    /// is chosen whenever it is still there, main or not.
    static func browsingWindow(
        among windows: [AXWindowSnapshot],
        preferring wanted: CGWindowID? = nil,
        identify: (AXWindowSnapshot) -> CGWindowID? = { _ in nil }
    ) -> AXWindowSnapshot? {
        func holdsThePage(_ window: AXWindowSnapshot) -> Bool {
            guard let root = window.root else { return false }
            var found = false
            root.forEachNode { node in
                guard !found else { return }
                if node.role == toolbarRole || node.category == .webArea { found = true }
            }
            return found
        }
        let browsing = windows.filter(holdsThePage)
        if let wanted, let kept = browsing.first(where: { identify($0) == wanted }) {
            return kept
        }
        return browsing.first(where: \.isMain)
            ?? browsing.first
            ?? windows.first(where: \.isMain)
            ?? windows.first
    }

    static let toolbarRole = "AXToolbar"

    /// WHERE THE PAGE IS, from what the window published. Pure, so both browsers'
    /// arrangements can be pinned without either browser running.
    ///
    /// The web area's own frame is the WHOLE SCROLLABLE DOCUMENT — measured at 3101pt
    /// tall inside an 842pt Safari window — so it is clipped to the window rather than
    /// used as given. Capturing the unclipped rect would ask for pixels that are not on
    /// screen and land every click a screenful off.
    public static func pageFrame(
        window: CGRect?,
        toolbars: [CGRect],
        webArea: CGRect?,
        source: PluginWebPageFrameSource
    ) -> (CGRect?, String) {
        guard let window, window.width > 0, window.height > 0 else { return (nil, "no window") }

        if source == .webArea, let webArea {
            let visible = webArea.intersection(window)
            if visible.width > 32, visible.height > 32 {
                return (visible, "web area clipped to the window")
            }
        }

        // Everything below the LOWEST toolbar. Chrome stacks two — the navigation bar
        // and the bookmarks bar — and the page starts under both of them.
        let insideWindow = toolbars.filter { $0.intersects(window) && $0.width > window.width * 0.5 }
        if let lowest = insideWindow.map(\.maxY).max(), lowest < window.maxY - 32 {
            return (
                CGRect(x: window.minX, y: lowest, width: window.width, height: window.maxY - lowest),
                "window below the toolbar")
        }
        // A web area that was rejected above is still better than the whole window.
        if let webArea {
            let visible = webArea.intersection(window)
            if visible.width > 32, visible.height > 32 {
                return (visible, "web area clipped to the window")
            }
        }
        return (window, "the whole window")
    }

    /// The current address. Where it lives differs per browser and is declared: a
    /// browser with a live web area publishes AXURL on it; one whose page tree is
    /// asleep leaves only what its address field is showing.
    private static func url(
        pid: pid_t,
        nodes: [AXNodeSnapshot],
        webArea: AXNodeSnapshot?,
        registration: WebSurfaceRegistration,
        window: CGWindowID? = nil
    ) -> String? {
        if registration.schema.urlSource == .webArea, let webArea,
           let found = AXEngine.detail(
            pid: pid, nodeID: webArea.id, options: .shell, budget: .probe),
           let url = found.detail.nodes[webArea.id]?.url, !url.isEmpty {
            return url
        }
        guard let value = addressFieldValue(
                  pid: pid, registration: registration, preferring: window),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// The address field's OWN text, right now — whatever is actually sitting in it,
    /// typed or committed. Not `Reading.url`: that is one whole shell read old by the
    /// time a caller sees it, and the one moment this exists for is proving that a
    /// synthetic typing run landed before anything is submitted.
    ///
    /// PIN: THE SAME LOOKUP `url(...)` USES for a browser with no live web area — this
    /// is that branch, pulled out so `openLocation` can call it mid-flight rather than
    /// only ever seeing the address after a whole shell re-read.
    public static func addressFieldValue(
        pid: pid_t, registration: WebSurfaceRegistration, preferring wanted: CGWindowID? = nil
    ) -> String? {
        guard AXIsProcessTrusted(),
              // THE SHELL PRESET, NOT `.exhaustive` — see `Options.shell`. This
              // is the browser's toolbar; the page below it is read by the page
              // lane, when a skill asks, and never on the way to a text field.
              let snapshot = AXEngine.snapshot(pid: pid, options: .shell),
              // THE WORKING WINDOW'S FIELD, not the main window's — see `read`.
              let window = browsingWindow(
                  among: snapshot.windows, preferring: wanted, identify: \.windowID),
              let root = window.root
        else { return nil }
        var nodes: [AXNodeSnapshot] = []
        root.forEachNode { nodes.append($0) }
        guard let field = nodes.first(where: { registration.isAddressLabel($0.label) }),
              let found = AXEngine.detail(
                pid: pid, nodeID: field.id, options: .shell, budget: .probe)
        else { return nil }
        return found.detail.nodes[field.id]?.textValue
    }

    /// The window's CGWindowID, so a capture takes the window this walk described.
    /// The window-server id of the window at `frame` with `title`.
    ///
    /// PIN: THE TITLE TELLS STACKED WINDOWS APART. Every window a round opens
    /// sits at the same origin as the last, so the origin alone named the
    /// wrong one; the window list carries each window's name where the
    /// screen-recording grant allows, and a name that is there has to agree.
    private static func windowIdentifier(
        pid: pid_t, frame: CGRect?, title: String? = nil
    ) -> CGWindowID? {
        guard let frame, let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        var atTheOrigin: CGWindowID?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  abs(bounds.origin.x - frame.origin.x) < 2,
                  abs(bounds.origin.y - frame.origin.y) < 2,
                  let number = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            if let title, let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                if name == title { return number }
                continue
            }
            if atTheOrigin == nil { atTheOrigin = number }
        }
        return atTheOrigin
    }
}
