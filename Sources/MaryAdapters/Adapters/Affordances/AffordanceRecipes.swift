//
//  AffordanceRecipes.swift
//  MaryAdapter
//
//  DO THE THING ON SCREEN THAT ACCOMPLISHES THIS.
//
//  `click_on_page` presses what the user NAMED. This presses what would do
//  what they ASKED — and the difference is the whole reason it exists. "Can
//  you skip the ad" names nothing: the button is labelled "Skip Ads", the
//  request is a goal, and every lexical ladder in the house misses it. The
//  resolution rung that closes that gap is `AffordanceResolver`; this is the
//  hands on the other side of it.
//
//  IT IS NOT A BROWSER SKILL, and that is the point the user made when this
//  was designed: "these intents should be part of the smart ambient system
//  that helps support all plugins of any family and class." So it is an
//  APPENDED FACULTY — no application identity, no bundle id, no world, no
//  Settings toggle — the shape `looking` and the document-corpus adapter
//  already established. A browser gets a page walk because a browser has the
//  URL-bar hazard; everything else gets its own window walk; neither had to
//  declare anything.
//
//  IT WAITS, AND THAT IS A FEATURE. A skip button does not exist for the
//  first five seconds of an ad. A resolver that answered "I can't find that"
//  at t=0 would be honest and useless, so a miss re-reads on a short cadence
//  until the budget is spent — and only then refuses. The budget is
//  `BrowserAXReadiness.defaultSettleTimeout`'s six seconds, which was itself
//  sized to a measured web-content delay.
//
//  AMBIGUITY REFUSES BY NAME, exactly as `PageElementResolver` already does.
//  Two skip-shaped controls is a question, not a coin toss.
//

import AppKit
import ApplicationServices
import MaryAmbient
import Foundation

enum AffordanceRecipes {

    /// How long a goal may wait for its control to appear. Matches
    /// `BrowserAXReadiness.defaultSettleTimeout` on purpose: both are answers
    /// to "how long before absence is real".
    static let appearanceBudget: TimeInterval = 6
    /// Between re-reads. Long enough that a walk is not the page's main
    /// visitor, short enough that a five-second ad is caught promptly.
    static let retryInterval: UInt64 = 700_000_000

    // MARK: - Surfaces

    /// Where the act will happen. Resolved from what is IN FRONT, never from
    /// the browser ladder alone — that ladder can answer with a background
    /// browser from ledger evidence, which is right for "read the page" and
    /// wrong for "press the thing I am looking at".
    enum Surface {
        // NO BROWSER ARM. Pressing something on a web page goes through the
        // page-interaction lane — it scopes to the page's web area, verifies
        // focus by reading it back, and produces its own receipts. That lane
        // is deferred with the browser sub-engine, and an arm here that
        // pretended to press into a page would bypass every one of those
        // guards.
        case application(pid: pid_t, name: String, place: AmbientPlace)
        case failure(SkillOutcome)
    }

    static func surface() async -> Surface {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier else {
            return .failure(SkillOutcome(
                ok: false,
                summary: "I can't tell which application is in front, so there's nothing for me to act on."))
        }
        if AmbientPlaceResolver.isBrowser(bundleID: bundleID) {
            return .failure(SkillOutcome(
                ok: false,
                summary: "That's a web page, and I can't press things on one yet."))
        }
        return .application(
            pid: front.processIdentifier,
            name: front.localizedName ?? "that app",
            place: AmbientPlaceResolver.applicationPlace(forBundleID: bundleID))
    }

    // MARK: - The act

    static func actOnScreen(goal rawGoal: String) async -> SkillOutcome {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            return SkillOutcome(
                ok: false, summary: "What would you like me to do on screen?")
        }
        switch await surface() {
        case .failure(let outcome):
            return outcome
        case .application(let pid, let name, let place):
            return await act(goal: goal, pid: pid, name: name, place: place)
        }
    }

    private static func act(
        goal: String, pid: pid_t, name: String, place: AmbientPlace
    ) async -> SkillOutcome {
        if let block = AppAutomationGate.accessibilityBlock() {
            return SkillOutcome(ok: false, summary: block)
        }
        let scope = AmbientElementScope.affordances(in: place)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)

        var lastMiss: SkillOutcome?
        let deadline = Date().addingTimeInterval(appearanceBudget)
        repeat {
            let elements = PageElementReader.readWindowControls(in: application)
            AffordanceResolver.publish(elements, scope: scope)
            switch AffordanceResolver.resolve(
                goal: goal, in: elements, scope: scope) {
            case .one(let element):
                return await press(
                    element, pid: pid, name: name, application: application)
            case .ambiguous(let rivals):
                return SkillOutcome(
                    ok: false,
                    summary: PageElementResolver.ambiguityRefusal(
                        rivals, phrase: goal))
            case .none:
                lastMiss = SkillOutcome(
                    ok: false,
                    summary: "I can't find anything in \(name) that would \(goal). Ask me what's on screen and I'll read you what I can see.")
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: retryInterval)
        } while Date() < deadline
        return lastMiss ?? SkillOutcome(
            ok: false, summary: PageElementResolver.missRefusal(phrase: goal))
    }

    /// The same choreography the page lane runs, with the
    /// one difference an ordinary application forces: its receipt cannot be a
    /// page title, so the window's own title is the signature.
    private static func press(
        _ element: PageElement, pid: pid_t, name: String,
        application: AXUIElement
    ) async -> SkillOutcome {
        guard element.isEnabled else {
            return SkillOutcome(
                ok: false,
                summary: "\"\(PageElementResolver.shortened(element.label))\" is there but not available right now.")
        }
        guard let lease = await StageArbiter.shared.acquire(
            owner: "page-hands", onPreempt: {}) else {
            return SkillOutcome(
                ok: false,
                summary: "Something else is using the screen right now — "
                    + "give me a moment and ask again.")
        }
        defer { StageArbiter.shared.release(lease) }
        let hold = WorkspaceFocusTracker.shared.beginSelfDriving()
        defer { WorkspaceFocusTracker.shared.endSelfDriving(hold) }

        let raised = await VerifiedActivation.bringForward(pid: pid)
        if let refusal = raised.reason(app: name) {
            return SkillOutcome(ok: false, summary: refusal)
        }
        // RE-READ BEFORE TOUCHING — a frame is a coordinate, and a window
        // that re-laid out since is a window that would be pressed in the
        // wrong place.
        let fresh = PageElementReader.readWindowControls(in: application)
        guard let current = PageElementResolver.relocate(element, in: fresh) else {
            return SkillOutcome(
                ok: false,
                summary: "\"\(PageElementResolver.shortened(element.label))\" moved or vanished before I could reach it. Ask again and I'll take a fresh look.")
        }
        let label = PageElementResolver.shortened(current.label)
        let before = PageElementReader.windowSignature(in: application)
        guard await PageElementActions.press(current, pid: pid) else {
            return SkillOutcome(
                ok: false, summary: "I found \(label) but couldn't press it.")
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if PageElementReader.windowSignature(in: application) != before {
            return SkillOutcome(
                ok: true, summary: "Pressed \(label) in \(name).",
                archivePolicy: .stateSnapshot)
        }
        return SkillOutcome(
            ok: true,
            summary: "Pressed \(label) in \(name). Nothing visibly changed — look_at_screen can verify it.",
            archivePolicy: .stateSnapshot)
    }
}
