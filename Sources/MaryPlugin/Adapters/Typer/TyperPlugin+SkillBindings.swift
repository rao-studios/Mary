//
//  TyperPlugin+SkillBindings.swift
//  MaryBrain
//
//  WHAT: Writing Ability Skill bindings (type, resume, dictate, passages).
//  IN:   TyperPlugin.swift (sibling split)
//  OUT:  performTyping / DictationSession / PassageRecipes
//

import AppKit
import Foundation
import os

extension TyperPlugin {

    public var skillBindings: [SkillBinding] {
        [
            SkillBinding(
                name: "type_at_cursor",
                description: "Type prose at the user's cursor in any ordinary text surface. A fresh highlight returns to its source. Never type code or terminal commands.",
                parameters: [
                    .init(name: "text", type: "string", description: "The prose to type, exactly as it should appear.", required: true),
                    // PIN: no closed app list — roster is the rule.
                    .init(name: "app", type: "string", description: "The application's NAME, never a document title. Omit to type into the just-opened document, or into the surface in front of the user.",
                          required: false),
                    .init(name: "mode", type: "string", description: "compose for new prose, or replace_selection only when the user has highlighted the words to replace.",
                          required: false, enumValues: ["compose", "replace_selection"]),
                ],
                access: .tweak,
                backing: .native { args, _ in
                    guard let text = args["text"], !text.isEmpty else {
                        return SkillOutcome(ok: false, summary: "What should I write?")
                    }
                    guard let target = TypingSurface.resolve(
                        requested: args["app"],
                        preferredApplicationID: AmbientContextStore.shared
                            .route()?.routedWorld?.applicationID) else {
                        // Browser pages are unresolvable here (SelectionSurfacePolicy) — web writer owns them.
                        if let front = NSWorkspace.shared.frontmostApplication?
                            .bundleIdentifier,
                           AmbientPlaceResolver.isBrowser(bundleID: front) {
                            return SkillOutcome(
                                ok: false,
                                summary: "That's a browser page — I write there with type_in_web_page, which pastes at the page's cursor. Call type_in_web_page with the same text.")
                        }
                        return SkillOutcome(
                            ok: false,
                            summary: "I couldn't pick a text surface. Call type_at_cursor again with app set to a running application's NAME (never a document title) — or open the document first with its create Skill. I never type into code or a terminal.")
                    }
                    let selectedMode = args["mode"].flatMap(TypingMode.init(rawValue:))
                    guard args["mode"] == nil || selectedMode != nil else {
                        return SkillOutcome(
                            ok: false,
                            summary: "Use compose for new prose or replace_selection for highlighted text.")
                    }
                    // Fresh passage supersedes any paused one.
                    TypingSession.shared.clear()
                    // Explicit = named/staged; implicit = attention/frontmost (focus-steal gate still applies).
                    let explicit = args["app"] != nil
                        || StagedWritingSurface.shared.fresh() != nil
                    return await Self.performTyping(
                        text, target: target, mode: selectedMode ?? .compose,
                        explicitTarget: explicit)
                },
                spokenFailureHint: "check Accessibility in my Settings",
                stage: true,
                // Caret write skips PassageRegistry — unroutedWrite so handles re-anchor.
                unroutedWrite: true
            ),

            SkillBinding(
                name: "resume_typing",
                description: "Continue a paused typed passage exactly where it stopped — after the user clicked away or another action interrupted the typing.",
                access: .tweak,
                backing: .native { _, _ in
                    guard let paused = TypingSession.shared.take() else {
                        return SkillOutcome(ok: true, summary: "There's no paused passage — tell me what to write and I'll type it fresh.")
                    }
                    return await Self.performTyping(paused.remainder, target: paused.target)
                },
                spokenFailureHint: "check Accessibility in my Settings",
                stage: true,
                // Same unrouted caret write, remainder of the paused passage.
                unroutedWrite: true
            ),
            SkillBinding(
                name: "start_dictation",
                description: "Hold the cursor open so everything the user says next is typed as prose until they stop. For dictating a scene or a long passage aloud — not for one sentence, which is type_at_cursor.",
                parameters: [
                    .init(
                        name: "app",
                        type: "string",
                        description: "The application's NAME, never a document title. Omit to use the document in front of the user.",
                        required: false),
                ],
                access: .tweak,
                backing: .native { args, _ in
                    let result = await DictationSession.openSession(app: args["app"])
                    guard let held = result.held else {
                        return SkillOutcome(
                            ok: false,
                            summary: result.refusal ?? "I couldn't start dictating.")
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "Listening — \(held.spokenPlace). Everything said now goes on the page until the user says stop.")
                },
                spokenFailureHint: "check Accessibility in my Settings",
                stage: true,
                // Session spans are unrouted caret writes, like type_at_cursor.
                unroutedWrite: true
            ),

            SkillBinding(
                name: "stop_dictation",
                description: "Close a held dictation session and report how much was written.",
                access: .tweak,
                backing: .native { _, _ in
                    guard let closed = DictationSession.shared.close() else {
                        return SkillOutcome(
                            ok: true, summary: "I wasn't taking dictation.")
                    }
                    let words = closed.wordsTyped
                    return SkillOutcome(
                        ok: true,
                        summary: words == 0
                            ? "Stopped — nothing written."
                            : "Done — \(SpokenPhrase.countWord(words)) \(words == 1 ? "word" : "words").")
                },
                stage: true
            ),
        ] + PassageRecipes.skillBindings()
    }

}
