//
//  MaryPrompts.swift
//  MaryBrain
//
//  The system prompt: rebuilt every turn (via the brain's prompt provider) so
//  the injected clock is always right, teaching the subshell doctrine — small
//  commands, one at a time, results before decisions.
//

import MaryAmbient
import Foundation

public enum MaryPrompts {

    /// Turn-specific guidance that belongs after the route has been resolved.
    public static func ambientGuidance(for route: AmbientRoute?) -> String {
        guard let route else { return "" }
        var guidance: [String] = []
        if route.selectionDefinesTurn, route.writingTarget == .selection {
            guidance.append("""

            === Selected-text revision ===
            The selection captured from its source app is the exact text to change, even while Mary is frontmost. Draft the revision, then call `type_at_cursor` once with `mode: "replace_selection"`. Do not locate a passage, ask which application is active, or ask the user to repeat the selected text.
            """)
        } else if route.selectionDefinesTurn,
                  route.attention?.isDirectReference == true {
            guidance.append("""

            === Direct reference ===
            The user has text selected in \(route.attention?.world.displayName ?? "the active application"). Treat that exact selection as what “this”, “this line”, and “it” refer to. Use it directly; never ask the user to repeat selected text.
            """)
        }
        if route.intent == .architect {
            guidance.append("""

        === Architect mode ===
        Explore the design with the user before changing anything. State the
        goal, constraints, options, and a recommended next step. Use the
        application's integration knowledge and the user's project context to
        ground the plan; do not write or run commands until they ask.
        """
            )
        }
        return guidance.joined(separator: "\n")
    }

    /// THE SKILL EXECUTION LANE'S PROMPT. A thin adapter over `PromptPlan.full` now — the
    /// literals and their post-mortems live in `PromptCatalog+System`, one
    /// named section each, and the ORDER lives in the plan where it can be
    /// read at a glance and validated.
    ///
    /// The signature and every default are unchanged on purpose: a dozen call
    /// sites and pins depend on them, and this refactor is not allowed to be
    /// visible from outside. `PromptPlanGoldenTests` proves it against a
    /// frozen copy of the old function over a generated matrix.
    ///
    /// Use `systemRender(...)` instead when you also want the budget
    /// waterfall.
    public static func system(
        plugins: [any MaryAdapter],
        projects: [String: String],
        leadContext: [String] = [],
        ambientNotes: [String] = [],
        heldFacts: [String] = [],
        heldMentions: [String] = [],
        leadPlace: AmbientPlace? = nil,
        coActiveContext: [String] = [],
        standingDownFragmentOwners: Set<String> = [],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        systemRender(
            plugins: plugins, projects: projects,
            leadContext: leadContext,
            ambientNotes: ambientNotes,
            heldFacts: heldFacts, heldMentions: heldMentions,
            leadPlace: leadPlace,
            coActiveContext: coActiveContext,
            standingDownFragmentOwners: standingDownFragmentOwners,
            now: now, timeZone: timeZone, calendar: calendar
        ).text
    }

    /// The same render, WITH the per-section account of what it spent — for
    /// the Routes pane, and for a golden failure that can name the section it
    /// diverged in rather than a byte offset.
    public static func systemRender(
        plugins: [any MaryAdapter],
        projects: [String: String],
        leadContext: [String] = [],
        ambientNotes: [String] = [],
        heldFacts: [String] = [],
        heldMentions: [String] = [],
        leadPlace: AmbientPlace? = nil,
        coActiveContext: [String] = [],
        standingDownFragmentOwners: Set<String> = [],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        plan: PromptPlan = .full
    ) -> PromptRender {
        plan.render(PromptInputs(
            plugins: plugins, projects: projects,
            leadContext: leadContext,
            ambientNotes: ambientNotes,
            heldFacts: heldFacts, heldMentions: heldMentions,
            leadPlace: leadPlace,
            coActiveContext: coActiveContext,
            standingDownFragmentOwners: standingDownFragmentOwners,
            now: now, timeZone: timeZone, calendar: calendar))
    }

    /// The eyeless data sources, named for the voice, GENERATED FROM
    /// `AmbientWorld` rather than typed out here. The taxonomy has exactly one
    /// home; a prose copy of it in a prompt string is precisely how a new
    /// plugin gets added to the store and forgotten by the voice — the same
    /// drift that made the eyes set get spelled five times.
    static var ambientReachList: String {
        let names = AmbientWorld.dataSources.map(\.displayName)
        guard let last = names.last else { return "their apps and data" }
        guard names.count > 1 else { return "their \(last)" }
        return "their " + names.dropLast().joined(separator: ", ") + " and \(last)"
    }

    /// The store's rendering, shared by BOTH prompt providers so the voice and
    /// the Skill lane are told the same thing about the same facts. Empty (not
    /// an empty header) when the store holds nothing worth saying.
    static func heldSection(facts: [String], mentions: [String]) -> String {
        guard !facts.isEmpty || !mentions.isEmpty else { return "" }
        var section = "\n\n" + """
        === Still in hand ===
        Things I read or saw earlier in this conversation and am still \
        holding. Each line says how old it is. They are real reads, not \
        remembered impressions — but anything above may have moved on since, \
        so where live text and a held fact disagree, the live text wins.
        """
        for fact in facts {
            section += "\n\n\(fact)"
        }
        if !mentions.isEmpty {
            // THE SENTENCE THAT CAUSED THE INCIDENT, REWRITTEN. It used to say
            // "I have the bounds and can pull the text back up if they ask" —
            // offered beside `characters 68–916 of 916`, with no primitive
            // anywhere that accepted an end offset. That is a standing
            // invitation to address a document by number, and it was accepted:
            // hand-written AppleScript against `document 1`, five minutes of
            // silence, `-1728`.
            //
            // What changed is that there IS something now, and it is named
            // here: the handle at the front of each line, and the verbs that
            // take it. The last clause is a prohibition rather than guidance
            // because the failure was a MODEL BEHAVIOUR, and the numbers on
            // these lines are still there (they are for the reader, and
            // `AmbientFact.boundsPhrase` is right to print them).
            section += "\n\n" + """
            Also still held. Each line starts with a handle like [S1] — that \
            handle is how I pull the text back up (find_passage) or change it \
            (replace_passage, insert_passage, delete_passage), in whichever \
            app the document is in. Never count characters myself, and never \
            write a script to reach into a document by character number: the \
            numbers below are for me to read, never to address anything with.
            """
            for mention in mentions {
                section += "\n- \(mention)"
            }
        }
        return section
    }

}
