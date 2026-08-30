//
//  MaryPrompts+SeerModeTwo.swift
//  MaryBrain
//
//  Split out of MaryPrompts.swift (docs/DECOMPOSITION.md Wave 4) —
//  pure relocation, no declaration changed.
//

import MaryAmbient
import Foundation

extension MaryPrompts {

    /// `targetBrief`'s artifact sibling — the ARTIFACT a revision is about,
    /// resolved this turn from the artifact ledger. Turn-scoped exactly like
    /// the passage brief: composed at lane spawn, spent on one prompt, never
    /// entering lane or shared history. The full id leads because it is the
    /// one string the update verb's singular target accepts. Every noun and
    /// token below fills from the located artifact's DECLARED domain
    /// vocabulary — the sentences are engine-owned; the words for "layer"
    /// and "canvas" are not.
   /// twin of the bug that typed a revision at the caret. A voice told its
    /// only power is typing where the caret sits will describe a revision as
    /// something the user has to do themselves.
    ///
    /// BOTH LINES NAME THE SAME TWO ACTS IN THE SAME ORDER — compose new
    /// work, and revise what is already there — differing only in the register
    /// the discipline calls for, because code is not prose. Pinned by
    /// `capabilityLinesAreSymmetric`.
    ///
    /// THE SENTENCE IS ALWAYS MARY'S; only the NAME is substituted. A package
    /// may not author persona prose — that is the standing rule, and it is why
    /// this is a template over the registration's `displayName` rather than a
    /// `guidance` string the package supplies. It is also why there are two
    /// arms and not a table: a package that could add a third register could
    /// write Mary a new personality.
    public static func capabilityLine(for world: PinnedWorld) -> String {
        let name = AmbientApplicationIndexProvider.current
            .registration(id: world.applicationID)?.displayName ?? world.applicationID
        switch world.focus {
        case .coding:
            return "Right now you're pair-coding with the user in \(name) — your hands write new code into their project and revise the code already there, directly, as you speak."
        case .writing:
            return "Right now you're co-writing with the user in \(name) — your hands write new prose into their document and revise the words already there, directly, as you speak."
        }
    }

    /// The persona Seer receives as `instructions` — spoken-prose register
    /// without the Skill doctrine (Seer has no Skills; its context comes from
    /// the user's totem). With `groundedResults`, this becomes the FOLLOW-UP
    /// persona: the helper's actions really ran, and the one job is to report
    /// their outcome plainly.
    ///
    /// Because the totem is the ONLY context Seer has otherwise, two clauses
    /// below decide whether the voice speaks about the present or the past:
    /// `liveWork` (what is on screen, authoritative) and the retrieval
    /// doctrine (what is remembered, historical). Both ride every spoken
    /// pass — turn and follow-up alike.
    /// - Parameter liveWork: the ONE live section the arbiter granted this
    ///   turn — Xcode's focused file OR the writing app's document text. One
    ///   channel on purpose: `WorkspaceFocusArbiter.sections` guarantees the
    ///   coding and writing fulls never coexist (pinned by
    ///   `fullSectionsNeverCoexist`), so a second parameter could only ever
    ///   be empty while this one was full — two names for one thing, and two
    ///   places to forget to wire.
    /// - Parameter liveWorkWorld: which world `liveWork` came from, so the
    ///   register matches the app the way `system()`'s headers do.
    /// - Parameter readPassages: text READ for this turn — the fetch-first
    ///   pre-read, or a read the orchestrator lane performed and joined. It
    ///   rides the SAME block as `liveWork` and lands AFTER it, deliberately.
    ///
    ///   THE HAZARD THIS CLOSES (traced, live): a fetched passage rendered in
    ///   `helperClause` sits BEFORE the live-work clause, which then declares
    ///   the ambient 800-char excerpt "the ground truth… it supersedes them" —
    ///   so the freshly-read passage was outranked by the stale window the
    ///   user had scrolled away from. Two contradicting authorities in one
    ///   prompt is the subtlest failure in this whole area; there is exactly
    ///   ONE authority block here, and the read is its last word.
    /// - Parameter readReport: this pass exists only to speak `readPassages`
    ///   back. Selects the READ persona — which is NOT the `groundedResults`
    ///   persona: that one says "never repeat the content that was written",
    ///   which is literally an instruction not to read a passage aloud. Set by
    ///   `speakRoutineFollowUp` when every concrete outcome of the routine was
    ///   a read, which is the shape of a calendar, reminders or mail question.
    public static func seerInstructions(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        capability: String? = nil,
        groundedResults: String? = nil,
        liveWork: [String] = [],
        liveWorkWorld: LiveWorkWorld = .unled,
        heldFacts: [String] = [],
        heldMentions: [String] = [],
        readPassages: [String] = [],
        readReport: Bool = false,
        conversational: Bool = false,
        runningActions: [String] = [],
        lookUnderway: Bool = false
    ) -> String {
        seerRender(
            now: now, timeZone: timeZone, calendar: calendar,
            capability: capability, groundedResults: groundedResults,
            liveWork: liveWork, liveWorkWorld: liveWorkWorld,
            heldFacts: heldFacts, heldMentions: heldMentions,
            readPassages: readPassages, readReport: readReport,
            conversational: conversational,
            runningActions: runningActions,
            lookUnderway: lookUnderway
        ).text
    }

    /// The same render, WITH the per-section account of what it spent.
    public static func seerRender(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        capability: String? = nil,
        groundedResults: String? = nil,
        liveWork: [String] = [],
        liveWorkWorld: LiveWorkWorld = .unled,
        heldFacts: [String] = [],
        heldMentions: [String] = [],
        readPassages: [String] = [],
        readReport: Bool = false,
        conversational: Bool = false,
        runningActions: [String] = [],
        lookUnderway: Bool = false,
        plan: PromptPlan = .voice
    ) -> PromptRender {
        plan.render(PromptInputs(
            heldFacts: heldFacts, heldMentions: heldMentions,
            now: now, timeZone: timeZone, calendar: calendar,
            capability: capability, groundedResults: groundedResults,
            liveWork: liveWork, liveWorkWorld: liveWorkWorld,
            readPassages: readPassages, readReport: readReport,
            conversational: conversational,
            runningActions: runningActions,
            lookUnderway: lookUnderway))
    }

    /// Appended to Seer's instructions while background routines run: the
    /// new turn must not double-promise the earlier work. Unlike the old
    /// single-routine note, new requests DO still act — earlier actions keep
    /// running in parallel.
    public static func runningActionsNote(labels: [String]) -> String {
        let listed = labels.isEmpty ? "an earlier request" : labels.joined(separator: "; ")
        return """
        Note: actions from the user's EARLIER requests are still running in \
        the background (\(listed)) — their results will be spoken separately \
        when they finish. Answer the current message on its own; don't \
        re-promise the earlier work. New requests still act normally.
        """
    }

    /// Wire-only synthetic user message closing the follow-up request (the
    /// conversation otherwise ends on an assistant turn). Never stored.
    public static let followUpNudge =
        "(Your helper just finished attempting those actions. Report the grounded outcome in one short spoken sentence; if any action failed or is unconfirmed, clearly say it did not complete and never claim success. Don't narrate how, and don't restate the content.)"

    /// The read pass's closing nudge. The MIRROR of followUpNudge and its
    /// exact opposite in one respect: that one says "don't restate the
    /// content" (right for an edit, catastrophic for a read), this one asks
    /// for the content itself. Wire-only, never stored.
    ///
    /// Produced by `MaryBrain.speakRoutineFollowUp` for a routine whose
    /// every concrete outcome is a READ — the detached path a calendar or
    /// reminders question almost always takes, because a hosted model rarely
    /// makes the 250 ms join grace. It was unproduced for one slice while the
    /// in-turn second Seer pass was gone, and that gap is what made "what's on
    /// my calendar" come back as "I checked your calendar for you" with no
    /// events in it: the only reachable persona said "never repeat the content
    /// that was written".
    /// THE UNPROMPTED NUDGE — the one persona in this file that answers no
    /// question.
    ///
    /// Every other nudge here closes a turn the USER opened, and can therefore
    /// assume attention. This one interrupts, so its whole job is to earn the
    /// interruption in one sentence and then stop. The instructions are
    /// negative on purpose: the failure modes of unprompted speech are
    /// preamble ("I noticed that…"), narrating the obvious, and asking a
    /// question that demands a reply the user never invited.
    public static func ambientRemarkNudge(observation: String) -> String {
        "(Nobody asked you anything. Something changed while they were working"
            + " and you decided it was worth a word:\n\n\(observation)\n\n"
            + "Say it in ONE short spoken sentence, the way a person in the room"
            + " would mention it — no preamble, no \"I noticed\", no offering to"
            + " help, no question at the end. If it does not sound worth"
            + " interrupting for, reply with exactly NOTHING and say nothing"
            + " at all.)"
    }

    /// What a composer returns when the model judges the moment not worth it.
    /// A SECOND, LATER FLOOR: the scorer decides a thing is remarkable, the
    /// voice decides whether it is sayable, and either may refuse.
    public static let ambientDeclineToken = "NOTHING"

    public static let readBackNudge =
        "(You've now got the passage they asked for, at the end of your instructions — read it back to them: give them the words, quoting as much of it as the answer needs.)"
}
