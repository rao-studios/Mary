//
//  ClosedWorld.swift
//  MaryPlugin
//
//  A PLACE THAT IS SHUT, SAID ONCE.
//
//  Every read and every edit that needs an application running refuses the
//  same way: the application isn't open, launching it is the cost the guard
//  exists to refuse, so state the condition and stop. This file owns that
//  sentence and — much more importantly — the two OUTCOME SHAPES behind it.
//
//  THE TURN THIS FILE IS ABOUT, inherited verbatim from Bonnie because the
//  defects are not hypothetical. A user asked for "the latest note I made in
//  the Notes app" and heard: "That's done — Notes isn't open — show_note opens
//  it if you name a note." One sentence, five defects:
//
//    1. `ok: true` WITH `foundNothing` UNSET. That pair passes every gate that
//       checks `foundNothing` and nothing else: the read persona recites the
//       refusal to the user as though it were the passage; the ledger books a
//       spoken-read row; the runtime files it as an ambient FACT about that
//       application, to be re-served on later turns; the follow-up line
//       prefixes it "That's done"; and the named-read path carries it into the
//       voice's "I read this just now, it IS the authority" block.
//    2. IT NAMED A SKILL, IN THE INDICATIVE. "show_note opens it" is a
//       sentence a Skill-invoking model reads as a thing to go and do — and
//       that Skill LAUNCHES the application, which is the one act the guard
//       exists to prevent. The refusal routed straight back into the cold
//       launch it was written to avoid.
//
//  WHY THIS IS NOT AN ENUM ANY MORE. Bonnie's version was a case per compiled
//  application, `CaseIterable` with a `default`-less switch, so a sixth shut
//  world could not compile without a sentence. That was the right shape when
//  the applications were compiled and countable. Mary has none: an application
//  arrives as a Plugin, so an enum here would need a case for every package
//  anyone installs. What survives is the part that was actually load-bearing —
//  the two outcome contracts below — plus a sentence built from what the
//  package already knows.
//

import Foundation
import MaryAmbient

/// The refusal for an application that is not running, and for a document
/// that is not open inside one that is.
public enum ClosedWorld {

    /// THE SENTENCE. States the condition, names what would be lost, and
    /// names no Skill.
    ///
    /// `lost` is the application-specific half and is the reason this takes a
    /// parameter rather than reading a table: what a relaunch costs differs
    /// per application and is a fact its own package knows. A text editor's
    /// answer is "a new window would have none of the notes you had open" —
    /// specific, because the whole premise of that application is several
    /// windows at once, and naming the windows is naming the thing that would
    /// actually be gone. Omit it and the sentence still refuses correctly,
    /// just less usefully.
    public static func sentence(app: String, lost: String? = nil) -> String {
        guard let lost, !lost.isEmpty else {
            return "\(app) isn't open, and I'd have to start it."
        }
        return "\(app) isn't open — I'd have to start it, and \(lost)."
    }

    /// The same refusal when the APPLICATION is running but the thing the user
    /// meant is not in front of it. The split matters: "TextEdit isn't open"
    /// is wrong and confusing when TextEdit is plainly on screen with nothing
    /// selected.
    public static func nothingOpenSentence(app: String, subject: String) -> String {
        "\(subject) isn't open in front of \(app) — nothing says which one you mean."
    }

    /// A CLOSED PLACE REFUSING A READ: `ok: true`, `foundNothing: true`.
    ///
    /// `ok` stays TRUE because nothing was attempted and nothing broke —
    /// `ok: false` is read by the orchestrator as a failure it is entitled to
    /// RETRY, and retrying a read against an application that is still shut
    /// cannot succeed however many times it runs.
    ///
    /// `foundNothing` is what closes all five consequences at the top of this
    /// file at once. Every one of those gates already checks `!foundNothing`
    /// and nothing else; not one of them needed a change. The flag was simply
    /// never set.
    public static func read(app: String, lost: String? = nil) -> SkillOutcome {
        SkillOutcome(
            ok: true,
            summary: sentence(app: app, lost: lost),
            foundNothing: true)
    }

    /// A CLOSED PLACE REFUSING A CHANGE: `ok: false`, and `foundNothing`
    /// stays OFF.
    ///
    /// THE SPLIT IS BY WHAT THE USER ASKED FOR, and `foundNothing` does not
    /// close a change's consequences — it opens them. The silent-settle arm
    /// fires when every outcome of an action turn is `ok`, so "move chapter
    /// three into Act Two" against a shut application would settle SILENTLY:
    /// the user hears nothing at all about an edit that did not happen. And
    /// the history marker's verb ladder reads `!ok`, never `foundNothing`, so
    /// the turn would be recorded as done and the next turn would answer
    /// "what did you change?" from it.
    ///
    /// An unmade edit, reported as an answer, in silence, is the worst
    /// available outcome. `ok: false` is the only flag the user hears.
    public static func change(app: String, lost: String? = nil) -> SkillOutcome {
        SkillOutcome(ok: false, summary: sentence(app: app, lost: lost))
    }
}
