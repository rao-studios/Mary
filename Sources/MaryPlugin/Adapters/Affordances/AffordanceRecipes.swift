//
//  AffordanceRecipes.swift
//  MaryAdapter
//
//  WHAT: Press the control that accomplishes the asked-for goal.
//  IN:   AffordancePlugin / AffordanceResolver / PageElementReader
//  OUT:  PageElementActions.press
//  PIN:  Appended faculty, not a browser skill. Waits up to appearanceBudget.
//        Ambiguity refuses by name (PageElementResolver).
//

import AppKit
import ApplicationServices
import MaryAmbient
import Foundation

enum AffordanceRecipes {

    /// How long a goal may wait for its control. Matches BrowserAXReadiness.defaultSettleTimeout.
    static let appearanceBudget: TimeInterval = 6
    /// Between re-reads — catch a five-second ad without walking the page constantly.
    static let retryInterval: UInt64 = 700_000_000

    // MARK: - Surfaces

    /// Frontmost surface. Not the browser ladder (that can pick a background browser).
    enum Surface {
        // PIN: no browser arm — page-interaction lane owns web presses (deferred).
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

    /// Page-lane press, with the window title as receipt (apps have no page title).
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
        // Re-read before touching — a frame is a coordinate; layout may have moved.
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
