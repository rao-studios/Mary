//
//  MaryPrompts+SewnModeTwo.swift
//  MaryBrain
//
//  WHAT: Voice-lane prompt appendices (persona, follow-up / read nudges).
//  IN:   MaryPrompts.swift (sibling split)
//  OUT:  strings concatenated by MaryPrompts / PromptCatalog
//  PIN:  Body literals inside """ must stay byte-identical.
//
import MaryAmbient
import Foundation

extension MaryPrompts {

    /// Voice capability line for the pinned world. Template over displayName.
    /// PIN: PACKAGES MAY NOT AUTHOR PERSONA PROSE — that is why this stays a
    /// closed switch while the discipline axis itself is open. A craft Mary
    /// ships prose for gets its own arm; any other installed discipline gets
    /// the general line rather than a sentence a package wrote about her.
    public static func capabilityLine(for world: PinnedWorld) -> String {
        let name = AmbientApplicationIndexProvider.current
            .registration(id: world.applicationID)?.displayName ?? world.applicationID
        switch world.focus {
        case .coding:
            return "Right now you're pair-coding with the user in \(name) — your hands can write new code into their project and revise the code already there; this voice pass is not writing as it speaks."
        case .writing:
            return "Right now you're co-writing with the user in \(name) — your hands can write new prose into their document and revise the words already there; this voice pass is not writing as it speaks."
        default:
            return "Right now you're working alongside the user in \(name) — your hands can act there directly; this voice pass is not acting as it speaks."
        }
    }

    /// Sewn `instructions` persona. With groundedResults this is the follow-up persona.
    /// PIN: One authority block; readPassages land last.
    public static func sewnInstructions(
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
        inspiredSight: Bool = false,
        perceiving: Bool = false,
        awareness: [String] = []
    ) -> String {
        sewnRender(
            now: now, timeZone: timeZone, calendar: calendar,
            capability: capability, groundedResults: groundedResults,
            liveWork: liveWork, liveWorkWorld: liveWorkWorld,
            heldFacts: heldFacts, heldMentions: heldMentions,
            readPassages: readPassages, readReport: readReport,
            conversational: conversational,
            runningActions: runningActions,
            lookUnderway: lookUnderway,
            inspiredSight: inspiredSight,
            perceiving: perceiving,
            awareness: awareness
        ).text
    }

    /// The same render, WITH the per-section account of what it spent.
    public static func sewnRender(
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
        inspiredSight: Bool = false,
        perceiving: Bool = false,
        awareness: [String] = [],
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
            lookUnderway: lookUnderway,
            inspiredSight: inspiredSight,
            perceiving: perceiving,
            awareness: awareness))
    }

    /// While background routines run: don't double-promise. New requests still act.
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

    /// Unprompted ambient remark. Earn the interruption in one sentence, then stop.
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
    /// PIN: Scorer decides remarkable; voice decides sayable; either may refuse.
    public static let ambientDeclineToken = "NOTHING"

    /// Read-pass closing nudge — give them the words (opposite of followUpNudge).
    public static let readBackNudge =
        "(You've now got the passage they asked for, at the end of your instructions — read it back to them: give them the words, quoting as much of it as the answer needs.)"
}
