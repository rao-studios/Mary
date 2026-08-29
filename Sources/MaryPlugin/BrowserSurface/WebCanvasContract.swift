//
//  WebCanvasContract.swift
//  MaryPlugin
//
//  TELLING THE MODEL WHAT A DECLARED CANVAS ACTUALLY TAKES.
//
//  THE BUG THIS EXISTS TO FIX, because it is invisible from either end alone.
//  A package declares a rich contract — "a complete GLSL fragment shader with
//  a mainImage entry point, written now for this moment" — and the model never
//  sees a word of it. `AbilityRuntime.projectedSchema` takes the declared
//  parameter NAME and the ADAPTER's description, deliberately, because package
//  prose may never reach the prompt. So a model asked how it feels saw a Skill
//  called `show_feeling_shader` whose only guidance was "the text to place in
//  the tool's editor", and did the reasonable thing with it: invented a
//  parameter, passed the user's own sentence, and wrote no shader at all. The
//  run failed with "There was nothing to put in it", which is true, and points
//  at the wrong end of the problem.
//
//  THE RULE THAT MUST NOT BEND. `permitsAuthoredPromptText` is false for every
//  provenance, forever. Package prose is UI metadata; a package author must
//  never be able to write a sentence that lands in Mary's prompt, because the
//  distance from "describe your parameter" to "ignore all prior instructions"
//  is zero.
//
//  SO NOTHING HERE IS AUTHORED PROSE. Every sentence below is Mary's own,
//  fixed, and written in this file. What a package contributes is TOKENS —
//  `contentNoun`, `requiredContentMarker` — each of them constrained by
//  `AbilityPackageValidator+WebCanvas` to a short, charset-bounded word before
//  it can ever arrive here. This is the same trade `permitsDerivedContractLabel`
//  already makes for the registry label: a validated identifier shaped into a
//  Mary-owned sentence is not authored text, and it is the difference between
//  a model that knows it is writing a shader and one that does not.
//
//  A TOKEN IS QUOTED WHEREVER IT LANDS, for the same reason: quoting is what
//  makes a word a word rather than a clause, so even a token that slipped the
//  validator reads as data inside the sentence rather than as instruction.
//

import Foundation
import MaryFoundation

public enum WebCanvasContract {

    /// What to say about the `content` parameter, given what is installed.
    ///
    /// PER TURN, not per build. `canvasBindings` is a computed property and
    /// the roster is reconciled on every package activation, so a canvas
    /// installed after launch describes itself correctly without a restart.
    public static func parameterSentence(for canvases: [WebCanvasRegistration]) -> String {
        switch canvases.count {
        case 0:
            // Nothing installed; the operation will refuse anyway. The
            // adapter's own words are the honest description of a lane with
            // no canvas behind it.
            return "The text to place in the tool's editor."
        case 1:
            let schema = canvases[0].schema
            var sentence = "The \(quoted(schema.contentNoun)) to place."
            if let marker = schema.requiredContentMarker, !marker.isEmpty {
                sentence += " It must contain \(quoted(marker))."
            }
            sentence += " At most \(kilobytes(schema.contentLimitBytes))."
            return sentence
        default:
            // TWO CANVASES IS A QUESTION, and `WebCanvasSupport.resolve`
            // already refuses to guess between them. Saying so here is what
            // stops the model finding that out by failing.
            let nouns = canvases.map { quoted($0.schema.contentNoun) }
            return "The text to place — a " + list(nouns)
                + ". Say which tool in `canvas`."
        }
    }

    /// What the browser surface tells the model before it calls anything.
    ///
    /// THE STANDING INSTRUCTION IS THE COMPETITION, and this is the lesson the
    /// predecessor paid for: its system prompt told the model to leave Skills
    /// alone during ordinary talk, and a fragment that merely DESCRIBED the
    /// Skill lost to that rule every time. The clauses about authoring and
    /// about not reading the result aloud are Mary's, fixed, and are the half
    /// that changes behaviour — a schema alone says what the parameter is, not
    /// that the model is the one who has to write it.
    ///
    /// Nil when nothing is installed: a fragment describing a lane with no
    /// canvas behind it is roster cost for nothing.
    public static func promptFragment(for canvases: [WebCanvasRegistration]) -> String? {
        guard !canvases.isEmpty else { return nil }
        let nouns = canvases.map { quoted($0.schema.contentNoun) }
        var text = "web canvas: a tool that runs what you write — "
            + list(nouns) + ". "
        text += "Write it yourself, now, in full; never send the user's own words as the "
        text += "content and never reach for one you wrote before. "
        if canvases.count == 1,
           let marker = canvases[0].schema.requiredContentMarker, !marker.isEmpty {
            text += "It must contain \(quoted(marker)). "
        }
        text += "Say what the tool said about it afterwards, and never read the "
        text += "content aloud."
        return text
    }

    // MARK: - Shaping

    /// Quoted, and stripped of anything that could end the quotation. A
    /// validated token cannot contain these; this is the belt to the
    /// validator's braces, and costs nothing.
    static func quoted(_ token: String) -> String {
        let clean = token.filter { !"\"\n\r".contains($0) }
        return "\"\(clean)\""
    }

    /// "32k" — the unit a person uses for a paste limit. Rounded down, so the
    /// number spoken is always one the editor will actually accept.
    static func kilobytes(_ bytes: Int) -> String {
        bytes >= 1000 ? "\(bytes / 1000)k" : "\(bytes) bytes"
    }

    /// "a, b or c" — Mary's list, not a package's.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default:
            return items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
        }
    }
}
