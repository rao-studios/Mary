//
//  BrowserSurfaceAdapter+Interact.swift
//  MaryPlugin
//
//  RUNNING A BOUNDED PLAN AGAINST ONE PAGE.
//
//  The same choreography the single-act verbs use, repeated under one stage
//  lease — and with the same re-read before every step, which matters MORE
//  here rather than less. A plan's second step runs on a page its first step
//  changed: a form that revealed a field, a control that moved as an error
//  message appeared above it. Resolving every step against the read taken at
//  the start would press whatever slid into place.
//
//  IT STOPS AT THE FIRST STEP THAT DOES NOT LAND, and says which. A plan that
//  carried on past a failed fill would submit a form with an empty field —
//  the failure compounding into an action the user did not ask for. Stopping
//  is recoverable; continuing is not.
//
//  AND IT REPORTS WHAT IT DID. There is no partial success that reads as
//  success: three of five steps is "I did three of five, and stopped at the
//  fourth because…", which is a sentence the user can act on.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

extension BrowserSurfaceAdapter {

    var interactBindings: [SkillBinding] { [interactWithPage] }

    static func interactOperations(adapterID: AdapterID) -> [InstalledAdapterBinding] {
        [
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: "interact_with_page",
                capabilities: ["browsing.page.interact"],
                inputTypes: ["browsing.interaction-plan"],
                outputTypes: ["browsing.operation-result"],
                observesPerceptions: ["perception.browser-page"],
                targetClasses: ["browser-page"]),
        ]
    }

    private var interactWithPage: SkillBinding {
        SkillBinding(
            name: "interact_with_page",
            description: """
            Do several things to the page in order — fill a form and submit \
            it, say. Call list_page_elements first and copy labels from it \
            exactly.

            \(PageInteractionPlan.authoringContract)
            """,
            parameters: [
                .init(
                    name: "plan", type: "string",
                    description: "The steps, one per line.", required: true),
                Self.browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let raw = arguments["plan"], !raw.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should I do on the page?")
                }
                let steps: [PageInteractionStep]
                switch PageInteractionPlan.parse(raw) {
                case .success(let parsed): steps = parsed
                case .failure(let issue):
                    return SkillOutcome(ok: false, summary: issue.spoken)
                }
                // ADMITTED WHOLE, BEFORE ANYTHING IS PRESSED. A plan that will
                // fail at step four should fail before step one: half a login
                // is worse than none, because the user cannot see which half
                // happened.
                let issues = PageInteractionPlan.validate(steps)
                guard issues.isEmpty else {
                    return SkillOutcome(
                        ok: false,
                        summary: issues.map(\.spoken).joined(separator: " "))
                }

                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                switch await pageTarget(arguments["browser"]) {
                case .ready(let found, let process):
                    registration = found
                    browser = process
                case .refusal(let outcome): return outcome
                }

                // ONE STAGE LEASE FOR THE WHOLE PLAN — the reason a plan
                // exists rather than three skill calls. Taken once, here.
                let activation = await VerifiedActivation.bringForward(
                    pid: browser.processIdentifier, requireVisibleWindow: true)
                guard activation.succeeded else {
                    return SkillOutcome(
                        ok: false,
                        summary: activation.reason(app: registration.displayName)
                            ?? "I couldn't bring \(registration.displayName) forward.")
                }

                return await run(steps, pid: browser.processIdentifier)
            })
    }

    /// Perform the steps, stopping at the first that does not land.
    func run(_ steps: [PageInteractionStep], pid: pid_t) async -> SkillOutcome {
        let application = WebSurface.application(pid: pid)
        var done: [String] = []

        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled else {
                return Self.report(done, stoppedAt: index, because: "I was interrupted")
            }

            if step.verb == .wait {
                try? await Task.sleep(for: .seconds(step.seconds ?? 0.25))
                done.append("waited")
                continue
            }

            // THE RE-READ, PER STEP. A plan's second step runs on a page its
            // first step changed — a revealed field, a control pushed down by
            // an error message. Resolving against the opening read would press
            // whatever moved into place.
            let pool = step.verb == .fill
                ? PageControlsReader.read(inApp: application).filter { $0.kind == .field }
                : PageControlsReader.read(inApp: application)
            guard !pool.isEmpty else {
                return Self.report(
                    done, stoppedAt: index,
                    because: step.verb == .fill
                        ? "there was nothing to type into"
                        : "the page had nothing I could press")
            }

            let element: PageElement
            switch PageElementResolver.resolve(phrase: step.target, in: pool) {
            case .one(let found): element = found
            case .ambiguous(let rivals):
                return Self.report(
                    done, stoppedAt: index,
                    because: PageElementResolver.ambiguityRefusal(
                        rivals, phrase: step.target))
            case .none:
                return Self.report(
                    done, stoppedAt: index,
                    because: "I couldn't find \"\(step.target)\" on the page")
            }

            let landed: Bool
            switch step.verb {
            case .press:
                landed = await PageElementActions.press(element, pid: pid)
            case .reveal:
                landed = PageElementActions.reveal(element)
            case .fill:
                guard PageElementActions.focus(element) else {
                    return Self.report(
                        done, stoppedAt: index,
                        because: "I couldn't put the caret in \"\(element.label)\"")
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard await WebSurface.replaceAll(with: step.text ?? "") else {
                    landed = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
                // READ IT BACK, as the single-act fill does. A field that
                // silently rejected the paste looks identical to one that
                // took it, and the next step would submit the form anyway.
                let value = AX.string(element.axElement, kAXValueAttribute) ?? ""
                landed = value.contains(step.text ?? "")
            case .wait:
                landed = true
            }

            guard landed else {
                return Self.report(
                    done, stoppedAt: index,
                    because: "\(step.verb.rawValue)ing \"\(element.label)\" didn't take")
            }
            done.append("\(step.verb.rawValue)ed \"\(PageElementResolver.shortened(element.label))\"")

            // A BEAT BETWEEN STEPS. The page needs one to respond before the
            // next step re-reads it, and without this every plan resolves its
            // second step against the page as it was before the first.
            try? await Task.sleep(for: .milliseconds(600))
        }

        return SkillOutcome(
            ok: true,
            summary: done.isEmpty ? "Nothing to do." : "Done: \(done.joined(separator: ", "))."
        )
    }

    /// The honest partial report. THERE IS NO PARTIAL SUCCESS: a plan that
    /// stopped is `ok: false`, however much of it ran, because the thing the
    /// user asked for did not happen.
    static func report(_ done: [String], stoppedAt index: Int, because reason: String) -> SkillOutcome {
        let prefix = done.isEmpty
            ? "I stopped at step \(index + 1)"
            : "I did \(done.joined(separator: ", ")), then stopped at step \(index + 1)"
        return SkillOutcome(ok: false, summary: "\(prefix) — \(reason).")
    }
}
