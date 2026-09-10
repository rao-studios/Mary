//
//  MaryPrompts.swift
//  MaryBrain
//
//  WHAT: System / Sewn instruction adapters over PromptPlan.
//  IN:   prompt provider (rebuilt every turn)
//  OUT:  PromptCatalog+System / +Voice / +SewnModeOne / +SewnModeTwo
//  PIN:  Clock is why the prompt is rebuilt; body literals stay byte-identical.
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
                  route.world?.isDirectReference == true {
            guidance.append("""

            === Direct reference ===
            The user has text selected in \(route.world?.attention.displayName ?? "the active application"). Treat that exact selection as what “this”, “this line”, and “it” refer to. Use it directly; never ask the user to repeat selected text.
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

    /// Skill-execution lane prompt. Thin adapter over `PromptPlan.full`.
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

    /// Same render with a per-section spend account (Routes pane / golden diffs).
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

    /// Eyeless data sources, named for the voice. Generated from `AmbientAttention`.
    static var ambientReachList: String {
        let names = AmbientAttention.dataSources.map(\.displayName)
        guard let last = names.last else { return "their apps and data" }
        guard names.count > 1 else { return "their \(last)" }
        return "their " + names.dropLast().joined(separator: ", ") + " and \(last)"
    }

    /// Store rendering shared by both prompt providers. Empty (not an empty header) when nothing to say.
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
            // Handle-led sentence for the Skill lane (find/replace/insert/delete_passage).
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
