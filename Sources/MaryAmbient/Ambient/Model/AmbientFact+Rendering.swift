//
//  AmbientFact+Rendering.swift
//  MaryBrain
//
//  ONE implementation of the phrasing, TWO readers.
//
//  The prompt providers and the debugger pane both render facts, and the whole
//  point of the store is that they cannot disagree about what Mary holds.
//  So the pane calls `mentionLine` — the very function the prompt calls — and
//  a pinned test compares the two byte for byte. Anything that phrases a fact
//  belongs in this file; a second spelling anywhere is the drift this
//  subsystem was built to end.
//
//  Two rules the phrasing must keep:
//    • The register follows the OWNING WORLD, exactly as `BonniePrompts.system`
//      chooses its headers — a Pages session must never hear "file".
//    • Bounds are never invented, and the age is never omitted. A budget loser
//      degrades to a one-line MENTION, never to silence, so anything Mary is
//      holding can always be asked about.
//

import Foundation

public extension AmbientFact {

    /// The prompt's and the pane's shared phrasing for WHAT this fact is.
    var slotPhrase: String {
        switch slot {
        case .namedRead(_, let phrase): return "the part about \"\(phrase)\""
        case .selection:           return "their highlight"
        case .objectSelection:     return "what they have selected"
        case .viewport:            return anchor?.displayName ?? "what they're looking at"
        // "their cursor" is `PerceptionAnchor.caret.displayName`, which is
        // where this fact's anchor comes from — asked of the anchor for the
        // same reason `.viewport` asks it, so the two slots can never end up
        // with two spellings of one idea. The fallback is that same word,
        // written out, for a fact that somehow arrived without an anchor.
        case .cursor:              return anchor?.displayName ?? "their cursor"
        case .file:
            // A coding place has files; everywhere else has documents. Bonnie
            // asked `world == .xcode` here, which was the same question while
            // exactly one compiled world was a coding place.
            return place.focus == .coding
                ? "the file in front of them" : "the document in front of them"
        case .project:             return "the project"
        case .git:                 return "version control"
        // Register follows the owning world, as the header rule says — and
        // for an eyeless source the honest register is "nothing is open, this
        // is just how things stand".
        case .digest:              return "how things stand right now"
        // Both of these are things she HOLDS rather than things she is
        // looking at, and the phrasing has to say so — a glimpse read as
        // "what they're looking at" would invite the model to narrate a
        // screen that has since changed.
        case .heard:               return "something said near her"
        case .glimpsed:            return "something she saw a moment ago"
        }
    }

    /// The bounds, said out loud, or "" when the fact cannot honestly say.
    /// Three tiers, exactly as `PagesContextWatcher.windowLine` established:
    /// a real range, a size against the whole, or nothing at all.
    var boundsPhrase: String {
        if let bounds, let total = documentTotal, total > 0,
           bounds.lowerBound >= 0, bounds.upperBound <= total, !bounds.isEmpty {
            return "characters \(bounds.lowerBound)–\(bounds.upperBound) of \(total)"
        }
        if let total = documentTotal, total > 0, content.count < total {
            return "about \(content.count) characters of \(total)"
        }
        if let bounds, !bounds.isEmpty {
            return "characters \(bounds.lowerBound)–\(bounds.upperBound)"
        }
        return ""
    }

    /// The age, and — past the fresh window — the honest warning that goes
    /// with it. A stale fact keeps its place and loses its authority.
    func agePhrase(at now: Date = Date()) -> String {
        let stamp = "\(registration.verb) \(AmbientAge.string(age(at: now))) ago"
        return isFresh(at: now) ? stamp : stamp + ", so it may have moved on since"
    }

    /// The ONE-LINE MENTION — what a budget loser degrades to (never a silent
    /// omission), and what the eyes tab renders as a row. Carries its bounds
    /// and its age, so even the cheapest rendering can be asked about.
    func mentionLine(at now: Date = Date()) -> String {
        // THE HANDLE LEADS, and it leads because of what it replaces. Every
        // other thing on this line is a DESCRIPTION — a world, a document
        // name, a character range, an age — and a description is something the
        // model can only talk about. `[S1]` is the one token on the line that
        // a Skill will actually accept, so it goes where the eye lands first.
        //
        // Adding it HERE and nowhere else is the whole reason this file exists:
        // `mentionLine` is the single phrasing the prompt and the eyes tab both
        // render, so the handle reaches the voice's prompt, the Skill execution lane's
        // prompt and the debugger pane from one line of code, and the pinned
        // byte-for-byte comparison between prompt and pane stays true.
        var line = ""
        if let passageHandle, !passageHandle.isEmpty { line += "[\(passageHandle)] " }
        // THE PLACE'S NAME, not the world's. A registered application rides
        // `.applications`, whose displayName is "Applications" — rendering that
        // would tell the user Mary is holding something from a world rather
        // than from Sketch, which is true of the storage and false of the fact.
        line += place.displayName
        if let subject, !subject.isEmpty { line += " · \(subject)" }
        line += " — \(slotPhrase)"
        let bounds = boundsPhrase
        if !bounds.isEmpty { line += ", \(bounds)" }
        line += ", \(agePhrase(at: now))"
        if spokenAt != nil { line += "; already spoken about" }
        // A STANDING DIGEST CARRIES ITS OWN WORDS. Every other slot's mention
        // is a POINTER — "the part about tides, characters 40–900, I can pull
        // it back up" — because the thing it points at is a passage. A digest
        // IS one line; a mention that withheld it would say "Reminders — how
        // things stand right now" and tell nobody anything, on the pane and in
        // the prompt alike. Mention-only is a budget policy, not a gag.
        if case .digest = slot, !content.isEmpty { return line + ": \(content)" }
        return line + "."
    }

    /// The FULL rendering: the mention line as a header, then the text.
    /// `limit` bounds the WHOLE block, header included — a budget that only
    /// bounded the body would be a budget the header could walk straight
    /// through, and the header is the part that is never allowed to be cut
    /// (it carries the bounds and the age).
    func block(at now: Date = Date(), limit: Int = contentCap) -> String {
        // A digest's mention already IS its whole text (see above) — building
        // a header plus a body here would print the same words twice.
        if case .digest = slot, !content.isEmpty {
            let line = mentionLine(at: now)
            return line.count > limit
                ? String(line.prefix(max(0, limit - 1))) + "…" : line
        }
        let header = String(mentionLine(at: now).dropLast()) + ":"
        let room = limit - header.count - 1
        guard room > 0 else { return header }
        let body = content.count > room
            ? String(content.prefix(max(0, room - 1))) + "…"
            : content
        return body.isEmpty ? header : header + "\n" + body
    }
}
