//
//  ClosedWorld.swift
//  MaryPlugin
//
//  WHAT: Worlds Mary may not invent skills for.
//  OUT:  skill admission

import Foundation
import MaryAmbient

/// The refusal for an application that is not running, and for a document
/// that is not open inside one that is.
public enum ClosedWorld {

    /// THE SENTENCE. States the condition, names what would be lost, and names no Skill.
    public static func sentence(app: String, lost: String? = nil) -> String {
        guard let lost, !lost.isEmpty else {
            return "\(app) isn't open, and I'd have to start it."
        }
        return "\(app) isn't open — I'd have to start it, and \(lost)."
    }

    /// The same refusal when the APPLICATION is running but the thing the user meant is not
    /// in front of it.
    public static func nothingOpenSentence(app: String, subject: String) -> String {
        "\(subject) isn't open in front of \(app) — nothing says which one you mean."
    }

    /// A CLOSED PLACE REFUSING A READ: `ok: true`, `foundNothing: true`.
    public static func read(app: String, lost: String? = nil) -> SkillOutcome {
        SkillOutcome(
            ok: true,
            summary: sentence(app: app, lost: lost),
            foundNothing: true)
    }

    /// A CLOSED PLACE REFUSING A CHANGE: `ok: false`, and `foundNothing` stays OFF.
    public static func change(app: String, lost: String? = nil) -> SkillOutcome {
        SkillOutcome(ok: false, summary: sentence(app: app, lost: lost))
    }
}
