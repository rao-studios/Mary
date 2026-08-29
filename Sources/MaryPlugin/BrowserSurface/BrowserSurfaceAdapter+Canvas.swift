//
//  BrowserSurfaceAdapter+Canvas.swift
//  MaryPlugin
//
//  THE WEB-CANVAS OPERATION — one Skill binding, any declared web tool.
//
//  It lives on the browser adapter because a canvas is reached through a
//  browser and every step of the choreography is this lane's: resolve a
//  browser, take the stage, open a tab, find an editor, place text, read the
//  page back. What the canvas contributes is words, and they arrive from
//  `WebCanvasSchema`.
//
//  NO SITE IS NAMED HERE, and none is named in `WebCanvasComposition`
//  either. The first canvas to use this is a shader editor; the second could
//  be a REPL or a diagram renderer, and neither would touch this file.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

extension BrowserSurfaceAdapter {

    var canvasBindings: [SkillBinding] { [composeInWebCanvas] }

    static func canvasOperations(adapterID: AdapterID) -> [InstalledAdapterBinding] {
        [
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: "compose_in_web_canvas",
                capabilities: ["browsing.canvas.compose"],
                inputTypes: ["browsing.canvas-request"],
                outputTypes: ["browsing.canvas-verdict"],
                observesPerceptions: ["perception.browser-page"],
                // A CANVAS, not a page. The Capability constrains to this
                // class so a package cannot bind an ordinary browsing verb to
                // an operation that opens a tab and pastes into it.
                targetClasses: ["web-canvas"]),
        ]
    }

    private var composeInWebCanvas: SkillBinding {
        SkillBinding(
            name: "compose_in_web_canvas",
            description: """
            Put a body of text into a web tool that runs it — a shader editor, \
            a code sandbox — and report what the tool said about it.
            """,
            parameters: [
                .init(
                    name: "content", type: "string",
                    // DERIVED FROM THE DECLARATION, in Mary's words. A fixed
                    // sentence here is what let a model call this Skill
                    // without ever learning it was supposed to write a shader.
                    // See `WebCanvasContract`.
                    description: WebCanvasContract.parameterSentence(
                        for: WebCanvasSupport.shared.all()),
                    required: true),
                .init(
                    name: "opening", type: "string",
                    description: "The sentence to say before the tool's verdict.",
                    required: false),
                .init(
                    name: "canvas", type: "string",
                    description: "Which tool. Omit when only one is installed.",
                    required: false),
                Self.browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let content = arguments["content"], !content.isEmpty else {
                    return SkillOutcome(ok: false, summary: "There was nothing to put in it.")
                }
                guard let canvas = WebCanvasSupport.shared.resolve(arguments["canvas"]) else {
                    let installed = WebCanvasSupport.shared.all()
                    return SkillOutcome(
                        ok: false,
                        summary: installed.isEmpty
                            ? "I don't have a web tool set up to do that in."
                            : "Which one — "
                                + installed.map(\.displayName).joined(separator: " or ") + "?")
                }

                let registration: BrowserSurfaceRegistration
                let browser: BrowserTarget
                // A DESTINATION, NOT A PAGE. The canvas is somewhere Mary is
                // being sent, so a machine with no browser open gets one
                // opened rather than a refusal — and `pageTarget`'s arrival
                // check is skipped here because the tab does not exist yet.
                // `WebCanvasComposition` does its own, after navigating.
                switch await canvasTarget(arguments["browser"]) {
                case .browser(let found, let process):
                    registration = found
                    browser = process
                case .refused(let outcome): return outcome
                }

                // THE STAGE, before a tab is opened. Everything after this
                // types and presses chords, and a chord sent while another
                // application holds the screen lands in that application.
                let activation = await VerifiedActivation.bringForward(
                    pid: browser.processIdentifier, requireVisibleWindow: true)
                guard activation.succeeded else {
                    return SkillOutcome(
                        ok: false,
                        summary: activation.reason(app: registration.displayName)
                            ?? "I couldn't bring \(registration.displayName) forward.")
                }

                let noun = canvas.schema.contentNoun
                switch await WebCanvasComposition.compose(
                    content, canvas: canvas.schema, pid: browser.processIdentifier,
                    bundleID: browser.bundleID) {
                case .failure(let failure):
                    return SkillOutcome(
                        ok: false,
                        summary: failure.spoken(
                            browser: registration.displayName, noun: noun))
                case .success(let outcome):
                    let opening = arguments["opening"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let spoken = WebCanvasComposition.spoken(
                        outcome.verdict,
                        noun: noun,
                        opening: opening?.isEmpty == false
                            ? opening!
                            : "Here's the \(noun).")
                    return SkillOutcome(
                        ok: spoken.ok,
                        summary: spoken.summary,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }
}
