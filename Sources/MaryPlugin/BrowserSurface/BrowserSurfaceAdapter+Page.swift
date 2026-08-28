//
//  BrowserSurfaceAdapter+Page.swift
//  MaryPlugin
//
//  VOICE AS THE MOUSE — acting on the page rather than on the browser.
//
//  The tab verbs address the BROWSER: which page is in front, open another,
//  close that one. These address what is IN the page — press this, type into
//  that, bring the other into view — and the difference matters because the
//  page is the part Mary did not write, cannot predict, and must re-read
//  before every single act.
//
//  THE CHOREOGRAPHY, and every step of it is load-bearing:
//
//    ENUMERATE → RESOLVE → RE-READ → ACT ON EXACTLY ONE THING → REPORT
//
//  The re-read is the step that looks redundant and is not. A page reflows
//  continuously — an ad loads, a feed appends, an image finishes decoding —
//  so an element resolved a second ago may now be at a different frame or
//  gone. Acting on the earlier read would press whatever moved into its
//  place, which is a wrong action that reports success. So the act relocates
//  by IDENTITY against a fresh read and refuses if it cannot find its target
//  again.
//
//  THESE ACT IN THE TAB THE USER IS ALREADY IN. Nothing here navigates;
//  `open_location` is the verb for going somewhere, deliberately separate, so
//  a click that fails cannot silently become a page load.
//
//  AMBIGUITY REFUSES BY NAME. "Play" on a page with four players is a
//  question, and `PageElementResolver` composes the sentence that asks it.
//  Picking one is right a quarter of the time and never questioned.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

extension BrowserSurfaceAdapter {

    var pageBindings: [SkillBinding] {
        [listPageElements, clickOnPage, fillInPage, scrollToOnPage]
    }

    /// The manifest half, so the page operations declare as fully as the tab
    /// ones do — see the adapter's header on why a bare operation installs
    /// BLOCKED.
    static func pageOperations(adapterID: AdapterID) -> [InstalledAdapterBinding] {
        func operation(
            _ name: String, capability: CapabilityID,
            input: ValueTypeID, output: ValueTypeID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                inputTypes: [input], outputTypes: [output],
                observesPerceptions: ["perception.browser-page"],
                targetClasses: ["browser-page"])
        }
        return [
            operation(
                "list_page_elements", capability: "browsing.page.read",
                input: "browsing.browser-query", output: "browsing.page-elements"),
            operation(
                "click_on_page", capability: "browsing.page.press",
                input: "browsing.element-request", output: "browsing.operation-result"),
            operation(
                "fill_in_page", capability: "browsing.page.fill",
                input: "browsing.element-request", output: "browsing.operation-result"),
            operation(
                "scroll_to_on_page", capability: "browsing.page.reveal",
                input: "browsing.element-request", output: "browsing.operation-result"),
        ]
    }

    // MARK: - Reading what the page offers

    private var listPageElements: SkillBinding {
        SkillBinding(
            name: "list_page_elements",
            description: """
            List what can be clicked or typed into on the page, numbered \
            within each kind. Call this before click_on_page or fill_in_page \
            and copy a label from it exactly.
            """,
            parameters: [
                .init(
                    name: "kind", type: "string",
                    description: "Narrow to one kind: link, button, field, video, image, heading.",
                    required: false),
                .init(
                    name: "browser", type: "string",
                    description: "Which browser. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let found: (BrowserSurfaceRegistration, BrowserTarget)
                switch await pageTarget(arguments["browser"]) {
                case .ready(let registration, let browser): found = (registration, browser)
                case .refusal(let outcome): return outcome
                }
                let elements = PageControlsReader.read(
                    inApp: WebSurface.application(pid: found.1.processIdentifier))
                guard !elements.isEmpty else {
                    return SkillOutcome(
                        ok: true,
                        summary: "There's nothing on that page I can press or type into.",
                        foundNothing: true,
                        adapterTrail: [AdapterID.normalized(name)])
                }

                let wanted = arguments["kind"].flatMap(Self.kind(named:))
                let shown = wanted.map { kind in
                    elements.filter { $0.kind == kind }
                } ?? elements
                guard !shown.isEmpty else {
                    // NAMING WHAT IS THERE rather than reporting an empty
                    // list: the useful next sentence is almost always about
                    // one of the kinds the page does offer.
                    let offered = Set(elements.map(\.kind.spokenWord)).sorted()
                    return SkillOutcome(
                        ok: true,
                        summary: "No \(wanted?.spokenWord ?? "matching") elements there. "
                            + "The page offers: \(offered.joined(separator: ", ")).",
                        foundNothing: true,
                        adapterTrail: [AdapterID.normalized(name)])
                }

                // NUMBERED WITHIN KIND, because "the third video" is what a
                // person says — never "the seventeenth element".
                var counters: [PageElementKind: Int] = [:]
                let lines = shown.prefix(Self.spokenLimit).map { element -> String in
                    let next = (counters[element.kind] ?? 0) + 1
                    counters[element.kind] = next
                    return "\(element.kind.spokenWord) \(next): "
                        + PageElementResolver.shortened(element.label)
                }
                let more = shown.count > Self.spokenLimit
                    ? "\n… and \(shown.count - Self.spokenLimit) more."
                    : ""
                return SkillOutcome(
                    ok: true,
                    summary: "On this page:\n" + lines.joined(separator: "\n") + more,
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Acting on one thing

    private var clickOnPage: SkillBinding {
        SkillBinding(
            name: "click_on_page",
            description: """
            Press one thing on the page — a link, a button, a control. Use a \
            label exactly as list_page_elements showed it.
            """,
            parameters: [Self.targetParameter, Self.browserParameter],
            access: .tweak,
            backing: .native { arguments, _ in
                await act(arguments, verb: "press") { element, pid in
                    await PageElementActions.press(element, pid: pid)
                }
            })
    }

    private var fillInPage: SkillBinding {
        SkillBinding(
            name: "fill_in_page",
            description: "Type text into one field on the page, replacing what is there.",
            parameters: [
                Self.targetParameter,
                .init(
                    name: "text", type: "string",
                    description: "What to put in the field.", required: true),
                Self.browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let text = arguments["text"] else {
                    return SkillOutcome(ok: false, summary: "What should I type in it?")
                }
                return await act(arguments, verb: "fill", kinds: [.field]) { element, pid in
                    // FOCUS FIRST AND PROVE IT. A paste with the caret
                    // somewhere else lands somewhere else, and the page
                    // reports nothing either way.
                    guard PageElementActions.focus(element) else { return false }
                    try? await Task.sleep(for: .milliseconds(150))
                    // A PASTE, not the typer: a field with an autocomplete
                    // attached fires on every keystroke, and a chunked type
                    // races a dropdown that rewrites what is underneath it.
                    return await WebSurface.replaceAll(with: text)
                }
            })
    }

    private var scrollToOnPage: SkillBinding {
        SkillBinding(
            name: "scroll_to_on_page",
            description: "Bring one thing on the page into view without pressing it.",
            parameters: [Self.targetParameter, Self.browserParameter],
            access: .tweak,
            backing: .native { arguments, _ in
                await act(arguments, verb: "reveal") { element, _ in
                    // AX's OWN ACTION, never a synthesized scroll at a
                    // coordinate — that would move whatever scroller happened
                    // to be under the pointer, which on a page with a nested
                    // feed is regularly not the one anybody meant.
                    PageElementActions.reveal(element)
                }
            })
    }

    // MARK: - The shared choreography

    /// Resolve a browser, wake its page, and prove the page is readable.
    /// Separate from the tab verbs' `target` because these additionally
    /// require the PAGE — a tab can be listed without one.
    enum PageTarget {
        case ready(BrowserSurfaceRegistration, BrowserTarget)
        case refusal(SkillOutcome)
    }

    func pageTarget(_ named: String?) async -> PageTarget {
        guard let resolved = support.resolve(named) else {
            let running = support.runningDisplayNames()
            return .refusal(SkillOutcome(
                ok: false,
                summary: running.count > 1
                    ? "\(running.joined(separator: " and ")) are both open — which one?"
                    : (named.map { "\($0) isn't running." } ?? "No browser I know is running.")))
        }
        let (registration, browser) = resolved
        // THE WAKE, AND ITS VERDICT. A Chromium page nobody asked for reads
        // as no page at all; calling that "nothing on the page" is the one
        // mistake this whole lane exists to avoid.
        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: browser.processIdentifier, bundleID: browser.bundleID)
        if readiness == .axTreeAbsent {
            return .refusal(SkillOutcome(
                ok: false,
                summary: WebSurface.Failure.pageNotExposed
                    .spoken(browser: registration.displayName)))
        }
        return .ready(registration, browser)
    }

    /// Enumerate, resolve, stage, RE-READ, relocate, act, report.
    ///
    /// `perform` receives the element found in the FRESH read, never the one
    /// resolution matched — see the file header.
    func act(
        _ arguments: [String: String],
        verb: String,
        kinds: Set<PageElementKind>? = nil,
        perform: (PageElement, pid_t) async -> Bool
    ) async -> SkillOutcome {
        guard let phrase = arguments["target"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty
        else { return SkillOutcome(ok: false, summary: "Which one?") }

        let registration: BrowserSurfaceRegistration
        let browser: BrowserTarget
        switch await pageTarget(arguments["browser"]) {
        case .ready(let found, let process):
            registration = found
            browser = process
        case .refusal(let outcome): return outcome
        }
        let pid = browser.processIdentifier
        let application = WebSurface.application(pid: pid)

        let pool = kinds.map { wanted in
            PageControlsReader.read(inApp: application).filter { wanted.contains($0.kind) }
        } ?? PageControlsReader.read(inApp: application)
        guard !pool.isEmpty else {
            return SkillOutcome(
                ok: true,
                summary: kinds == nil
                    ? "There's nothing on that page I can press."
                    : "There's nothing on that page I can type into.",
                foundNothing: true)
        }

        let chosen: PageElement
        switch PageElementResolver.resolve(phrase: phrase, in: pool) {
        case .one(let element): chosen = element
        case .ambiguous(let rivals):
            return SkillOutcome(
                ok: false,
                summary: PageElementResolver.ambiguityRefusal(rivals, phrase: phrase))
        case .none:
            return SkillOutcome(
                ok: true,
                summary: PageElementResolver.missRefusal(phrase: phrase),
                // A MISS IS NOT A FAILURE. The read worked; the thing named
                // is not on the page, and saying so plainly is the answer.
                foundNothing: true)
        }

        // The browser must own the screen before anything is pressed: a click
        // into a background window is a real act with an invisible result.
        let activation = await VerifiedActivation.bringForward(
            pid: pid, requireVisibleWindow: true)
        guard activation.succeeded else {
            return SkillOutcome(
                ok: false,
                summary: activation.reason(app: registration.displayName)
                    ?? "I couldn't bring \(registration.displayName) forward.")
        }

        // THE RE-READ. Raising the window alone can reflow the page, so this
        // is not merely guarding against a slow user — the act itself moved
        // things.
        let before = PageControlsReader.pageSignature(pid: pid)
        let fresh = PageControlsReader.read(inApp: application)
        guard let target = Self.relocate(chosen, in: fresh) else {
            return SkillOutcome(
                ok: false,
                summary: """
                "\(PageElementResolver.shortened(chosen.label))" moved before I \
                could \(verb) it. Ask me again and I'll look afresh.
                """)
        }

        guard await perform(target, pid) else {
            return SkillOutcome(
                ok: false,
                summary: "I couldn't \(verb) \"\(PageElementResolver.shortened(target.label))\".")
        }
        try? await Task.sleep(for: .milliseconds(1200))

        // WHAT THE PAGE DID, as far as can be seen. An unchanged title means
        // nothing observable happened — which is honest, and is NOT the same
        // as the press having failed. Plenty of real actions change nothing.
        let after = PageControlsReader.pageSignature(pid: pid)
        let moved = before != after
        return SkillOutcome(
            ok: true,
            summary: moved
                ? "Pressed \"\(PageElementResolver.shortened(target.label))\" — \(after ?? "the page") now."
                : "\(verb.capitalized)ed \"\(PageElementResolver.shortened(target.label))\".",
            target: ActedElementReader.record(of: target.axElement, pid: pid),
            adapterTrail: [AdapterID.normalized(name)])
    }

    /// Find the same thing again in a fresh read.
    ///
    /// BY IDENTITY, NEVER BY POSITION. A URL is the strongest signal a link
    /// has; failing that, the label and role together. An ordinal would find
    /// whatever slid into the gap, which is the precise failure this exists
    /// to prevent — and it would report success.
    static func relocate(_ element: PageElement, in fresh: [PageElement]) -> PageElement? {
        if let url = element.url, !url.isEmpty,
           let hit = fresh.first(where: { $0.url == url }) {
            return hit
        }
        return fresh.first {
            $0.role == element.role
                && PageElementResolver.normalized($0.label)
                    == PageElementResolver.normalized(element.label)
        }
    }

    // MARK: - Vocabulary

    /// What one read says out loud. The published read is larger; a spoken
    /// list of sixty is a list nobody hears the end of.
    static let spokenLimit = 12

    static func kind(named raw: String) -> PageElementKind? {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PageElementKind.allCases.first { kind in
            kind.spokenWord == wanted || kind.admittingWords.contains(wanted)
        }
    }

    static var targetParameter: ModelSkillSchema.Parameter {
        .init(
            name: "target", type: "string",
            description: "The label of the thing to act on, exactly as list_page_elements showed it.",
            required: true)
    }

    static var browserParameter: ModelSkillSchema.Parameter {
        .init(
            name: "browser", type: "string",
            description: "Which browser. Omit for the one in front.",
            required: false)
    }
}
