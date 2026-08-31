//
//  AmbientFact+Rendering.swift
//  MaryBrain
//
//  WHAT: One phrasing, two readers — prompt and pane both call mentionLine.
//  IN:   AmbientFact
//  OUT:  prompt / debugger. Register follows owning world (AmbientPlace.focus).
//  PIN:  Bounds never invented; age never omitted. Budget loser degrades to a mention, never silence.
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
        // "their cursor" is `PerceptionAnchor.caret.displayName`, which is where this fact's
        // anchor comes from — asked of the anchor for the same reason `.viewport` asks it, so the
        // two slots can never end up with two spellings of one idea.
        case .cursor:              return anchor?.displayName ?? "their cursor"
        case .file:
            // A coding place has files; everywhere else has documents.
            return place.focus == .coding
                ? "the file in front of them" : "the document in front of them"
        case .project:             return "the project"
        case .git:                 return "version control"
        // Register follows the owning world — and for an eyeless source the honest register is
        // "nothing is open, this is just how things stand".
        case .digest:              return "how things stand right now"
        // Both of these are things she HOLDS rather than things she is looking at, and the
        // phrasing has to say so — a glimpse read as "what they're looking at" would invite the
        // model to narrate a screen that has since changed.
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
        // THE HANDLE LEADS, and it leads because of what it replaces. Every other thing on this
        // line is a DESCRIPTION.
        var line = ""
        if let passageHandle, !passageHandle.isEmpty { line += "[\(passageHandle)] " }
        // THE PLACE'S NAME, not the world's.
        line += place.displayName
        if let subject, !subject.isEmpty { line += " · \(subject)" }
        line += " — \(slotPhrase)"
        let bounds = boundsPhrase
        if !bounds.isEmpty { line += ", \(bounds)" }
        line += ", \(agePhrase(at: now))"
        if spokenAt != nil { line += "; already spoken about" }
        // A STANDING DIGEST CARRIES ITS OWN WORDS. Every other slot's mention is a POINTER — "the
        // part about tides, characters 40–900, I can pull it back up" — because the thing it
        // points at is a passage.
        if case .digest = slot, !content.isEmpty { return line + ": \(content)" }
        return line + "."
    }

    /// The FULL rendering: the mention line as a header, then the text.
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
