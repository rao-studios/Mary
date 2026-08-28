//
//  BrowserSurfaceAdapter.swift
//  MaryPlugin
//
//  THE BROWSER'S VALUES, ANSWERED — the compiled half of the browsing lane.
//
//  A managed-UI recipe presses keys and returns nothing, so every browsing
//  verb that must hand the model a VALUE — the tab roster, what page is open,
//  the page's text — binds here instead. That is the same structural limit
//  that keeps three prose Skills and six multimedia Skills compiled, and it
//  is the whole reason the surface lanes exist.
//
//  NOTHING HERE NAMES A BROWSER. Which strip, which attribute, which chord
//  all arrive from `BrowserSurfaceRegistration`; what is compiled is only
//  what is true of every browser that publishes a tab strip. Adding a third
//  is a `.mary` file.
//
//  THE REFUSALS ARE THE INTERESTING PART, because a browsing turn has more
//  ways to be honestly impossible than to succeed: no declared browser is
//  running, two are and nothing said which, the strip is not where the
//  package said, the page has not been exposed yet, a name matched three
//  tabs. Each of those is a different sentence, and none of them is "that
//  didn't work".
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct BrowserSurfaceAdapter: MaryAdapter {

    public let name = "browser-surface"
    public let summary =
        "reads a browser's tabs and page text, switches and closes tabs, and opens addresses"

    let support: BrowserSurfaceSupport

    public init(support: BrowserSurfaceSupport = .shared) {
        self.support = support
    }

    public var skillBindings: [SkillBinding] {
        [listTabs, currentTab, activateTab, closeTab, openLocation, readPage]
            + pageBindings + canvasBindings + interactBindings
    }

    /// THE TYPED HANDSHAKE, DECLARED RATHER THAN DEFAULTED — and written this
    /// way from the first line because the media lane already paid for the
    /// lesson. The protocol's default manifest publishes an operation's NAME
    /// and nothing else: no capabilities, no Value types, no target classes.
    /// Every browsing Capability constrains itself with `allowedTargetClass:
    /// browser-page`, and `InstalledAdapterInventory` refuses a binding whose
    /// operation does not IMPLEMENT one of the allowed classes. An operation
    /// claiming no class implements none, so the Skills install, sit BLOCKED,
    /// and report themselves unavailable one at a time — while any Skill
    /// whose Capability happens to constrain nothing stays READY, which makes
    /// the whole failure look selective rather than structural.
    ///
    /// `providesPerceptions` is the same omission one level up: browsing
    /// Skills require `perception.browser-page`, the package declares it, and
    /// unless something PUBLISHES it every one of them is ineligible. Reading
    /// a browser's tabs and page is precisely what this adapter does.
    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String,
            capability: CapabilityID,
            input: ValueTypeID,
            output: ValueTypeID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: [capability],
                inputTypes: [input],
                outputTypes: [output],
                observesPerceptions: ["perception.browser-page"],
                targetClasses: ["browser-page"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Browser Surface",
            transport: .accessibility,
            operations: [
                operation(
                    "list_tabs",
                    capability: "browsing.tabs.read",
                    input: "browsing.browser-query",
                    output: "browsing.tab-roster"),
                operation(
                    "current_tab",
                    capability: "browsing.tabs.read",
                    input: "browsing.browser-query",
                    output: "browsing.tab-report"),
                operation(
                    "activate_tab",
                    capability: "browsing.tab.activate",
                    input: "browsing.tab-request",
                    output: "browsing.operation-result"),
                operation(
                    "close_tab",
                    capability: "browsing.tab.close",
                    input: "browsing.tab-request",
                    output: "browsing.operation-result"),
                operation(
                    "open_location",
                    capability: "browsing.location.open",
                    input: "browsing.location-request",
                    output: "browsing.operation-result"),
                operation(
                    "read_page",
                    capability: "browsing.page.read",
                    input: "browsing.browser-query",
                    output: "browsing.page-text"),
            ] + Self.pageOperations(adapterID: adapterID)
                + Self.canvasOperations(adapterID: adapterID)
                + Self.interactOperations(adapterID: adapterID),
            providesPerceptions: ["perception.browser-page"],
            supportedValueTypes: [
                "browsing.browser-query",
                "browsing.tab-roster",
                "browsing.tab-report",
                "browsing.tab-request",
                "browsing.location-request",
                "browsing.operation-result",
                "browsing.page-text",
                "browsing.page-elements",
                "browsing.element-request",
                "browsing.canvas-request",
                "browsing.canvas-verdict",
                "browsing.interaction-plan",
            ],
            // ACCESSIBILITY AND NOTHING ELSE. The predecessor's browsing lane
            // needed an Automation grant for its tab roster; this one reads
            // the same roster from the tree and asks for no second consent.
            grantedPermissions: [.accessibility])
    }

    // MARK: - Resolving a browser

    /// What resolving a browser produced: the pair, or the refusal ITSELF —
    /// composed here, where the rivals are in hand, rather than as a flag the
    /// caller has to turn back into a sentence.
    private enum Resolved {
        case browser(BrowserSurfaceRegistration, BrowserTarget)
        case refused(SkillOutcome)
    }

    /// Every act starts here.
    private func target(_ named: String?) -> Resolved {
        guard !support.all().isEmpty else {
            return .refused(SkillOutcome(
                ok: false,
                summary: "I don't have a browser set up to work with yet."))
        }
        guard let resolved = support.resolve(named) else {
            let running = support.runningDisplayNames()
            if running.isEmpty {
                return .refused(SkillOutcome(
                    ok: false,
                    summary: named.map { "\($0) isn't running." }
                        ?? "No browser I know is running."))
            }
            // TWO BROWSERS AND NOTHING SAID WHICH. The ladder refuses rather
            // than guessing, and this is where that refusal becomes a
            // question worth answering — naming them is what lets the user
            // settle it in one word.
            return .refused(SkillOutcome(
                ok: false,
                summary: named.map { "I couldn't find \($0) running." }
                    ?? "\(running.joined(separator: " and ")) are both open — which one?"))
        }
        return .browser(resolved.0, resolved.1)
    }

    /// ⚠️ AN ABSENT STRIP IS USUALLY ONE TAB, not a missing window — measured
    /// live, and the first version of this message got it backwards. Safari
    /// hides its tab bar entirely when a window holds a single tab, so the
    /// strip search correctly finds nothing and the honest answer is "just
    /// the one", not "I couldn't find your tabs".
    ///
    /// The window title is the evidence that tells them apart: a window with
    /// a title is a window showing a page.
    private func noStrip(
        _ registration: BrowserSurfaceRegistration, pid: pid_t
    ) -> SkillOutcome {
        guard let title = WebSurface.windowTitle(pid: pid), !title.isEmpty else {
            return SkillOutcome(
                ok: false,
                summary: "\(registration.displayName) has no window open right now.")
        }
        return SkillOutcome(
            ok: true,
            summary: "\(registration.displayName) has just the one tab open: \(title).",
            archivePolicy: .stateSnapshot,
            adapterTrail: [AdapterID.normalized(name)])
    }

    /// One spoken sentence per outcome the roster can produce. Kept in one
    /// place so activate and close cannot drift apart in how they refuse.
    static func spoken(
        _ outcome: BrowserTabRoster.Outcome, browser: String
    ) -> SkillOutcome {
        switch outcome {
        case .switched(let name):
            return SkillOutcome(ok: true, summary: "Switched to \(name).")
        case .closed(let name):
            return SkillOutcome(ok: true, summary: "Closed \(name).")
        case .noSuchTab(let offered):
            return SkillOutcome(
                ok: true,
                summary: offered.isEmpty
                    ? "There are no tabs open in \(browser)."
                    : "I don't see that tab. Open right now: \(offered.joined(separator: ", ")).",
                // A MISS, NOT A FAILURE. The read worked and the answer is
                // that the thing named is not there — which is worth saying
                // plainly rather than reporting as an error.
                foundNothing: true)
        case .ambiguous(let rivals):
            return SkillOutcome(
                ok: false,
                summary: "That matches \(rivals.joined(separator: " and ")) — which one?")
        case .noStrip:
            return SkillOutcome(
                ok: false, summary: "I couldn't read \(browser)'s tabs just now.")
        case .didNotTake(let name):
            // DELIVERED AND UNCONFIRMED IS NOT SUCCESS. The press went; the
            // roster did not move, or could not be read to prove it did.
            return SkillOutcome(
                ok: false,
                summary: "I pressed \(name) but \(browser) didn't move to it.")
        }
    }

    // MARK: - Reading

    private var listTabs: SkillBinding {
        SkillBinding(
            name: "list_tabs",
            description: "List the tabs open in a browser, numbered, saying which one is showing.",
            parameters: [
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }
                await BrowserAXReadiness.ensureWebContentAX(
                    pid: browser.processIdentifier, bundleID: browser.bundleID)

                let tabs = BrowserTabRoster.read(
                    pid: browser.processIdentifier, surface: registration.schema)
                guard !tabs.isEmpty else {
                    return noStrip(registration, pid: browser.processIdentifier)
                }

                // NUMBERED, because "the third one" is a thing people say and
                // the roster is the only place those numbers are honest —
                // they are resolved back to an element before anything is
                // pressed.
                let lines = tabs.map { tab in
                    "\(tab.ordinal). \(tab.name)\(tab.isCurrent == true ? " (showing)" : "")"
                }
                return SkillOutcome(
                    ok: true,
                    summary: "\(registration.displayName) has \(tabs.count) "
                        + "\(tabs.count == 1 ? "tab" : "tabs") open:\n"
                        + lines.joined(separator: "\n"),
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private var currentTab: SkillBinding {
        SkillBinding(
            name: "current_tab",
            description: "Say which page a browser is showing right now.",
            parameters: [
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }
                let tabs = BrowserTabRoster.read(
                    pid: browser.processIdentifier, surface: registration.schema)

                guard let current = tabs.first(where: { $0.isCurrent == true }) else {
                    // Either no strip, or the browser publishes no readable
                    // current-tab signal — the window title is what is left,
                    // and it is a true answer to "what am I looking at".
                    guard let title = WebSurface.windowTitle(pid: browser.processIdentifier)
                    else { return noStrip(registration, pid: browser.processIdentifier) }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) is showing \(title).",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
                return SkillOutcome(
                    ok: true,
                    summary: "\(registration.displayName) is showing \(current.name) "
                        + "(tab \(current.ordinal) of \(tabs.count)).",
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private var readPage: SkillBinding {
        SkillBinding(
            name: "read_page",
            description: """
            Read the text of the page a browser is showing, to answer a \
            question about it or summarise it.
            """,
            parameters: [
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }

                // THE WAKE MUST COME FIRST AND ITS VERDICT MUST BE READ. A
                // Chromium page nobody has asked for reads as no page at all,
                // and reporting that as an empty page is the one mistake this
                // whole lane exists to avoid.
                let readiness = await BrowserAXReadiness.ensureWebContentAX(
                    pid: browser.processIdentifier, bundleID: browser.bundleID)
                if readiness == .axTreeAbsent {
                    return SkillOutcome(
                        ok: false,
                        summary: WebSurface.Failure.pageNotExposed
                            .spoken(browser: registration.displayName))
                }

                guard let reading = WebPageText.read(
                    inApp: WebSurface.application(pid: browser.processIdentifier))
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: WebSurface.Failure.pageNotExposed
                            .spoken(browser: registration.displayName))
                }
                guard reading.contributingNodes > 0 else {
                    // A PAGE WITH NO WORDS IS A REAL STATE, not a failed
                    // read: a canvas, a video, a tree still filling in.
                    return SkillOutcome(
                        ok: true,
                        summary: "That page has no text I can read.",
                        foundNothing: true,
                        adapterTrail: [AdapterID.normalized(name)])
                }
                let title = WebSurface.windowTitle(pid: browser.processIdentifier)
                return SkillOutcome(
                    ok: true,
                    summary: (title.map { "\($0):\n" } ?? "")
                        + reading.text
                        + (reading.truncated ? "\n\n(That is the first part of the page.)" : ""),
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Acting

    /// Bring the browser forward and prove it, before anything is pressed.
    ///
    /// A TAB PRESS IN A BACKGROUND WINDOW is a real act with an invisible
    /// result, and the chord fallbacks land wherever focus actually is. This
    /// is the one road — `VerifiedActivation` — and the acts below take it
    /// rather than assuming the browser is where they left it.
    private func stage(
        _ browser: BrowserTarget, as registration: BrowserSurfaceRegistration
    ) async -> SkillOutcome? {
        // `requireVisibleWindow`, because a browser frontmost with every
        // window minimized is a browser with no tab strip to press and no
        // page to read — and a chord sent to it lands on nothing.
        let activation = await VerifiedActivation.bringForward(
            pid: browser.processIdentifier, requireVisibleWindow: true)
        guard !activation.succeeded else { return nil }
        return SkillOutcome(
            ok: false,
            summary: activation.reason(app: registration.displayName)
                ?? "I couldn't bring \(registration.displayName) forward.")
    }

    private var activateTab: SkillBinding {
        SkillBinding(
            name: "activate_tab",
            description: """
            Switch a browser to one of its open tabs, named or numbered as \
            list_tabs shows them.
            """,
            parameters: [
                .init(
                    name: "tab", type: "string",
                    description: "The tab's name, or its number from list_tabs.",
                    required: true),
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }
                guard let spoken = arguments["tab"], !spoken.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which tab?")
                }
                if let refusal = await stage(browser, as: registration) { return refusal }

                let outcome = await BrowserTabRoster.activate(
                    Self.parse(spoken), pid: browser.processIdentifier,
                    surface: registration.schema)
                var result = Self.spoken(outcome, browser: registration.displayName)
                result.adapterTrail = [AdapterID.normalized(name)]
                return result
            })
    }

    private var closeTab: SkillBinding {
        SkillBinding(
            name: "close_tab",
            description: "Close one of a browser's open tabs, named or numbered.",
            parameters: [
                .init(
                    name: "tab", type: "string",
                    description: "The tab's name, or its number from list_tabs.",
                    required: true),
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            // A TWEAK AND NOT A WRITE, on the same reasoning the package's
            // Capability uses: a closed tab reopens with ⌘⇧T and loses
            // nothing but its scroll position. It is reversible in the way
            // that matters, which is that the user can undo it themselves.
            access: .tweak,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }
                guard let spoken = arguments["tab"], !spoken.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which tab?")
                }
                if let refusal = await stage(browser, as: registration) { return refusal }

                let outcome = await BrowserTabRoster.close(
                    Self.parse(spoken), pid: browser.processIdentifier,
                    surface: registration.schema)
                var result = Self.spoken(outcome, browser: registration.displayName)
                result.adapterTrail = [AdapterID.normalized(name)]
                return result
            })
    }

    private var openLocation: SkillBinding {
        SkillBinding(
            name: "open_location",
            description: """
            Open a web address in a new browser tab. Give the address the user \
            said; never invent a path.
            """,
            parameters: [
                .init(
                    name: "url", type: "string",
                    description: "The address to open. http or https only.",
                    required: true),
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch target(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }
                guard let raw = arguments["url"], let url = Self.admit(raw) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I can only open http or https addresses.")
                }
                if let refusal = await stage(browser, as: registration) { return refusal }

                if let failure = await WebSurface.openLocation(
                    url, pid: browser.processIdentifier) {
                    return SkillOutcome(
                        ok: false,
                        summary: failure.spoken(browser: registration.displayName))
                }
                // THE SITE, NOT THE ADDRESS. A URL is held and never spoken —
                // reading one aloud is noise, and reading a long one aloud is
                // noise for twenty seconds.
                return SkillOutcome(
                    ok: true,
                    summary: "Opened \(Self.site(of: url)) in \(registration.displayName).",
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Parsing what the model said

    /// A bare number is an ordinal; anything else is a name.
    ///
    /// ORDINALS ARE ACCEPTED BECAUSE PEOPLE SAY THEM, and resolved back to an
    /// element before anything is pressed — see `BrowserTabRoster`. What is
    /// never done is carrying the number into the act.
    static func parse(_ spoken: String) -> BrowserTabRoster.Target {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ordinal = Int(trimmed), ordinal > 0 { return .ordinal(ordinal) }
        return .named(trimmed)
    }

    /// HTTP AND HTTPS ONLY, as an admission rather than a warning. A `file:`
    /// or `javascript:` address is not a browsing destination, and the place
    /// to refuse one is before a browser is asked to go there.
    static func admit(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048 else { return nil }
        // A bare host is what people say; the scheme is what a browser needs.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return candidate
    }

    /// The site's name, for saying out loud. `www.` dropped because nobody
    /// says it.
    static func site(of url: String) -> String {
        guard let host = URL(string: url)?.host else { return "the page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
