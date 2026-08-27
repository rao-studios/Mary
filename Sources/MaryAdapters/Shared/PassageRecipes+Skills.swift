//
//  PassageRecipes+Skills.swift
//

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - The Skills

    /// Registered by `TyperPlugin`. Five names, checked clear of every existing
    /// binding name in both directions (`PluginCatalogTests.pairwiseNonContainment`
    /// matches on substring containment, and Safari's `read_page` is the
    /// standing landmine that rules out anything shaped `read_pages_*`).
    ///
    /// ─────────────────────────────────────────────────────────────────────
    /// THE DESCRIPTION BUDGET, AND WHAT PAID FOR THE PLACEMENT DOCTRINE
    /// ─────────────────────────────────────────────────────────────────────
    ///
    /// Every one of these strings is in the system prompt of every turn, so a
    /// sentence added here is rent charged forever. `replace_passage` had to
    /// gain the placement rule — it is the mechanism the user's own decision
    /// rests on ("she should be intelligent enough to understand whether to
    /// insert the thought at the end, start, middle or wherever it makes the
    /// most sense") and nothing else in the tree tells the model that a
    /// recompose is CHEAP. `insert_passage` had to be narrowed to whole blocks
    /// so the two verbs stop competing for the same request.
    ///
    /// THREE SENTENCES WERE DELETED TO PAY FOR IT, and each one was already
    /// being said by the verb's own schema or by its own previous clause:
    ///
    ///   - `find_passage`: "Works in Xcode, Pages and Scrivener." — the `app`
    ///     parameter's `enumValues` ARE that list, rendered right beside it.
    ///   - `replace_passage`: "Pass the [S1] handle from find_passage, or name
    ///     the part." — the `passage` and `target` parameters say exactly this,
    ///     one line further down, in the place the model reads when it is
    ///     deciding what to put in them.
    ///   - `revert_last_edit`: "so it can never clobber their own work" — a
    ///     restatement of the clause immediately before it ("refuses if the
    ///     user has written over it since"), which is the same promise in the
    ///     words of what the verb actually does.
    ///
    /// THE ARITHMETIC: 650 characters across the five before, 695 after. The
    /// two new sentences cost 180 and the three deletions returned 135, so the
    /// placement doctrine is carried for 45 characters a turn.
    /// `PluginCatalogTests.descriptionBudget` caps any SINGLE binding at 250 and
    /// `replace_passage` is the longest at 222, so the per-binding ceiling is not
    /// what is scarce here — the total is, and nothing measures it.
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

            // THE PLACEMENT VERB. "To work a thought into the middle of one,
            // send the whole passage back with it woven in" is the user's
            // decision made operable — she judges where the sentence belongs
            // and hands back prose, rather than this file inventing a
            // within-passage anchor with its own ambiguity rules.
            //
            // "ONLY WHAT DIFFERS GETS WRITTEN" IS THE PART THAT MAKES IT SAFE
            // TO ASK FOR, and it is a fact rather than a reassurance:
            // `PassageEditRunner.writeSpan` routes every `.replace` through
            // `minimalChange`, so a five-paragraph section handed back with one
            // sentence changed reaches the writer as that one sentence, widened
            // only as far as it must be to appear exactly once. Without this
            // clause the model reads "send the whole passage back" as a
            // wholesale rewrite and declines to do it for anything large.
            editRecipe(
                name: "replace_passage",
                description: "Replace a located passage with new wording — the part itself changes where it sits, not at the cursor. To work a thought into the middle of one, send the whole passage back with it woven in; only what differs gets written.",
                extra: [
                    .init(name: "text", type: "string",
                          description: "The new wording, exactly as it should read.", required: true),
                ],
                operation: { _ in .replace }),

            // NARROWED TO WHOLE BLOCKS, and KEPT. The two verbs were competing
            // for the same request — "add this to the Background section" could
            // reasonably be either — and the tie went to whichever the model
            // reached for first, which is how a thought that belonged in the
            // middle of a paragraph arrived welded to its end.
            //
            // Folding it into `replace_passage` was the other option and it is
            // the wrong one: a genuinely new block has no passage to recompose,
            // and expressing "put a new paragraph after this one" as a replace
            // would make the model retype text it was not changing.
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
                    // "before" only when they said so. An insert whose position
                    // is unstated is an addition, and additions go after the
                    // thing they extend — putting a new paragraph in FRONT of
                    // the one it elaborates reads as a non sequitur.
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

    /// The three edit verbs differ in exactly two ways — the operation they
    /// perform and the arguments they take — so they are built from one factory
    /// and share the parameter set that carries the passage.
    ///
    /// BOTH `passage` AND `target` ARE OPTIONAL, and the runner says "which
    /// part should I change?" when both are missing. Declaring either one
    /// required would be a lie in one direction or the other: a follow-up turn
    /// has the handle and no phrase, a first turn has the phrase and no handle,
    /// and a schema that insisted on one would make the model invent the other.
    /// This is `XcodeEditError`'s precedent — ask for the one thing that would
    /// make the call work, in a sentence, rather than failing a schema check.
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
            // THE STAGE, claimed. See this file's header: the Pages backing may
            // fall back to keystrokes, and a binding that may type must preempt
            // the current stage holder or a live typed passage dies to the
            // focus steal instead of pausing resumably.
            stage: true
        )
    }

}
