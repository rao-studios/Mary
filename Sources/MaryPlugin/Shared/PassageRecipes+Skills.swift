//
//  PassageRecipes+Skills.swift
//
//  WHAT: Passage skill bindings (find / replace / insert / delete / revert).
//  IN:   PassageRecipes.swift (sibling split)
//  OUT:  PassageEditRunner

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - The Skills

    /// Registered by TyperPlugin. Names checked clear of every existing binding both ways.
    public static func skillBindings() -> [SkillBinding] {
        [
            SkillBinding(
                name: "find_passage",
                description: "Locate a part of the document the user is working in — by heading, phrase, or the words they used — and get its text plus a handle like [S1] to change it with.",
                parameters: [
                    .init(name: "target", type: "string",
                          description: "What they called it: a heading, a phrase, or the words themselves.",
                          required: true),
                    .init(name: "app", type: "string",
                          description: "Which app the document is in; omit for the one they're working in.",
                          required: false, enumValues: passageAppEnumValues),
                ],
                access: .read,
                backing: .native { args, _ in
                    switch route(handle: nil, requested: args["app"]) {
                    case .refused(let sentence):
                        return SkillOutcome(ok: false, summary: sentence)
                    case .backing(let backing):
                        return await PassageEditRunner.find(
                            handle: nil, target: args["target"], backing: backing)
                    }
                }
            ),

            // "To work a thought into the middle of one, send the whole passage back with
            // it woven in" is the user's decision made operable.
            editRecipe(
                name: "replace_passage",
                description: "Replace a located passage with new wording — the part itself changes where it sits, not at the cursor. To work a thought into the middle of one, send the whole passage back with it woven in; only what differs gets written.",
                extra: [
                    .init(name: "text", type: "string",
                          description: "The new wording, exactly as it should read.", required: true),
                ],
                operation: { _ in .replace }),

            // NARROWED TO WHOLE BLOCKS, and KEPT. The two verbs were competing for the same
            // request.
            editRecipe(
                name: "insert_passage",
                description: "Add a whole new block before or after a located passage, leaving it standing. Wording that belongs inside a passage goes through replace_passage.",
                extra: [
                    .init(name: "text", type: "string",
                          description: "The wording to add, exactly as it should read.", required: true),
                    .init(name: "position", type: "string",
                          description: "Put it before or after the passage (default after).",
                          required: false, enumValues: ["before", "after"]),
                ],
                operation: { args in
                    // "before" only when they said so. An insert whose position is unstated
                    // is an addition, and additions go after the thing they extend.
                    (args["position"] ?? "").lowercased().hasPrefix("before")
                        ? .insertBefore : .insertAfter
                }),

            editRecipe(
                name: "delete_passage",
                description: "Take a located passage out of the document, closing the gap it leaves behind.",
                extra: [],
                operation: { _ in .delete }),

            SkillBinding(
                name: "revert_last_edit",
                description: "Undo the last change I made to the document — refuses if the user has written over it since.",
                parameters: [
                    .init(name: "app", type: "string",
                          description: "Which app the document is in; omit for the one they're working in.",
                          required: false, enumValues: passageAppEnumValues),
                ],
                access: .tweak,
                backing: .native { args, _ in
                    switch route(handle: nil, requested: args["app"]) {
                    case .refused(let sentence):
                        return SkillOutcome(ok: false, summary: sentence)
                    case .backing(let backing):
                        return await PassageEditRunner.revert(backing: backing)
                    }
                },
                stage: true
            ),
        ]
    }

    /// The three edit verbs differ in exactly two ways — the operation they perform and the
    /// arguments they take — so they are built from.
    public static func editRecipe(
        name: String,
        description: String,
        extra: [ModelSkillSchema.Parameter],
        operation: @escaping @Sendable ([String: String]) -> PassageOperation
    ) -> SkillBinding {
        SkillBinding(
            name: name,
            description: description,
            parameters: [
                .init(name: "passage", type: "string",
                      description: "The [S1] handle from an earlier find_passage or read.",
                      required: false),
                .init(name: "target", type: "string",
                      description: "What they called the part: a heading, a phrase, or the words themselves.",
                      required: false),
            ] + extra + [
                .init(name: "app", type: "string",
                      description: "Which app the document is in; omit for the one they're working in.",
                      required: false, enumValues: passageAppEnumValues),
            ],
            access: .tweak,
            backing: .native { args, _ in
                switch route(handle: args["passage"], requested: args["app"]) {
                case .refused(let sentence):
                    return SkillOutcome(ok: false, summary: sentence)
                case .backing(let backing):
                    return await PassageEditRunner.edit(
                        operation(args),
                        handle: args["passage"], target: args["target"],
                        text: args["text"] ?? "", backing: backing)
                }
            },
            // THE STAGE, claimed. See this file's header: the Pages backing may fall back
            // to keystrokes, and a binding that may type must preempt the current stage
            // holder or a live typed passage dies to the focus steal instead of pausing
            stage: true
        )
    }

}
