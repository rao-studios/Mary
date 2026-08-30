//
//  PairedRead.swift
//  MaryBrain
//
//  ONE OBSERVATION PER ROW. This is the guard every listing in this tree that
//  reads a collection as SEPARATE whole-collection property gets is built on.
//
//  THE MIX-UP IT EXISTS TO MAKE IMPOSSIBLE. Reading a listing as
//  `id of <collection>`, then `sender of <collection>`, then
//  `subject of <collection>` is three Apple Events, and it is the right shape
//  for speed — three round trips whether the window is five messages or two
//  hundred, instead of four per row. But three events are three MOMENTS.
//  Mail's inbox index 1 is the NEWEST message, so a single email arriving
//  between the first get and the second shifts every index by one, and
//  `rawIDs[i]`, `rawSenders[i]`, `rawSubjects[i]` then describe three
//  different messages. The user hears sender A with subject B, and
//  `read_email` on that row's handle opens message C.
//
//  A COUNT CLAMP IS NOT THIS GUARD. Taking the shortest of the three lists
//  stops `item i of` running off the end; it does nothing whatever about the
//  pairing, because an arrival and a departure leave the lengths equal while
//  every row is shifted. That is precisely the "confidently wrong" answer —
//  plausible, specific, about the wrong object — that this codebase treats as
//  strictly worse than being slow. So the clamp is gone: a length that does
//  not match is now PROOF the collection moved, not something to work around.
//
//  WHAT IS ACTUALLY DONE. Bracket the reads with the identifier list —
//  identifiers, then the other properties, then the identifiers AGAIN — and
//  emit rows only if the two identifier lists are identical. One extra Apple
//  Event converts a silent mix-up into a detected one. Any attempt that comes
//  back moved (or errors, which is what a message deleted mid-read looks
//  like) is retried ONCE; if the second attempt is also inconsistent the read
//  returns `movedToken` instead of rows, and the caller says so out loud
//  rather than describing a mailbox that never existed.
//
//  WHY NOT ONE EVENT THAT RETURNS PAIRED DATA. It is the obvious fix and the
//  sdefs rule it out. `properties of …` is the only construct that carries
//  several properties of a row in a single get, and for all three apps this
//  tree lists it drags exactly the payload the fast shape removed:
//  Mail's `message` class declares `content`, `all headers` and `source` (the
//  raw message) as properties; Notes' `note` declares `body` (the HTML) and
//  `plaintext`; Safari's `tab` declares `source` and `text` (the whole page).
//  A two-hundred-message search window would fetch two hundred raw emails to
//  learn two hundred subject lines. Nothing in any of the three dictionaries
//  projects a SUBSET of properties across a collection in one event.
//
//  WHY NOT ANCHOR THE LATER READS TO THE IDENTIFIERS. Addressing each row by
//  id — `first message of inbox whose id is …`, `note id "x-coredata://…"` —
//  really is immune to a shift, and both forms are already proven in this
//  tree. But it costs one Apple Event PER ROW PER PROPERTY, which is the
//  fan-out the fast shape was written to delete; on `search_email`'s window
//  that is four hundred events inside one 30 s budget. It is the right
//  fallback only where it is affordable, and it is not affordable where the
//  mix-up is most likely.
//
//  A NOTE ON "JUST FALL BACK TO THE OLD LOOP". The loop this replaced read
//  `set aMessage to message i of inbox` and then took three properties off
//  `aMessage` — an INDEX-anchored specifier, re-resolved per property event.
//  It narrowed the window from the whole collection to one row, but it did
//  not close it. Falling back to it would restore a weaker version of the
//  same bug, which is why the terminal state here is an honest sentence.
//

import Foundation

public enum PairedRead {

    /// One column of a listing: the variable the app's answer lands in, the
    /// plain-list variable everything downstream reads, and the expression
    /// that fetches the whole column in one get.
    public struct Column {
        public let raw: String
        public let list: String
        public let expression: String

        public init(raw: String, list: String, expression: String) {
            self.raw = raw
            self.list = list
            self.expression = expression
        }
    }

    /// What a guarded read returns INSTEAD OF ROWS when it could not observe
    /// the collection twice unchanged.
    ///
    /// It carries no field separator, so it can never survive a row parser
    /// even if a caller forgets to check for it — and it is deliberately
    /// unspeakable, so a leak fails loudly instead of plausibly.
    public static let movedToken = "MARY-COLLECTION-MOVED"

    /// True when a script's output is the moved token rather than rows.
    ///
    /// Callers MUST test this before testing for emptiness: the token parses
    /// to zero rows, and "the inbox is empty" is exactly the confident wrong
    /// answer the bracket was added to prevent.
    public static func moved(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == movedToken
    }

    /// Emits the bracketed read.
    ///
    /// - `setup` runs inside the `tell` at the top of EVERY attempt, so a
    ///   range guard (`count`, then clamp) is re-taken on the retry — which is
    ///   what lets an attempt that failed because a message was deleted
    ///   succeed the second time round.
    /// - `identifiers` is read first and again last. The two reads use the
    ///   IDENTICAL expression on purpose: a recheck of a different collection
    ///   would prove nothing about the one the fields came from.
    /// - Everything after `end tell` is plain AppleScript list work that never
    ///   crosses the Apple Event boundary, which is why the `count of` and the
    ///   list comparison are free.
    ///
    /// Leaves `rowCount` and every `Column.list` variable bound for the
    /// caller's emit loop.
    public static func block(
        application: String,
        setup: [String] = [],
        identifiers: Column,
        fields: [Column]
    ) -> String {
        var lines: [String] = []
        lines.append("set rowsPaired to false")
        lines.append("repeat with attemptNumber from 1 to 2")
        lines.append("    try")
        lines.append("        tell application \"\(application)\"")
        for line in setup {
            lines.append("            \(line)")
        }
        lines.append("            set \(identifiers.raw) to \(identifiers.expression)")
        for field in fields {
            lines.append("            set \(field.raw) to \(field.expression)")
        }
        // THE BRACKET. Same expression, second look: if one row of this comes
        // back different, every field read between the two looks was taken
        // against a collection that was moving.
        lines.append("            set recheckIDs to \(identifiers.expression)")
        lines.append("        end tell")
        // `as list` is not decoration: a one-row collection can come back as a
        // bare value, and `count of` a string is its CHARACTER count.
        lines.append("        set \(identifiers.list) to \(identifiers.raw) as list")
        for field in fields {
            lines.append("        set \(field.list) to \(field.raw) as list")
        }
        lines.append("        set rowCount to count of \(identifiers.list)")
        lines.append("        set sameLengths to true")
        for field in fields {
            lines.append(
                "        if (count of \(field.list)) is not equal to rowCount then set sameLengths to false")
        }
        // Identifiers are text in Notes, and AppleScript compares text
        // case-insensitively unless told otherwise — which could call two
        // different ids equal and hide the very change being looked for.
        lines.append("        considering case")
        lines.append("            set sameRows to ((recheckIDs as list) is equal to \(identifiers.list))")
        lines.append("        end considering")
        lines.append("        if sameRows and sameLengths then")
        lines.append("            set rowsPaired to true")
        lines.append("            exit repeat")
        lines.append("        end if")
        // Retry once, then let the error through. A mutation mid-read shows up
        // as "invalid index" and deserves the second attempt; a denied
        // Automation permission fails identically both times and must reach
        // the user as the permission error it is, NOT as "the list moved".
        lines.append("    on error errorText number errorNumber")
        lines.append("        if attemptNumber is 2 then error errorText number errorNumber")
        lines.append("    end try")
        lines.append("end repeat")
        lines.append("if rowsPaired is false then return \"\(movedToken)\"")
        return lines.joined(separator: "\n")
    }
}
