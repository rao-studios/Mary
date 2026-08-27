//
//  PassageOutline.swift
//  MaryBrain
//
//  THE TABLE OF CONTENTS, rendered from the units a world's structure reader
//  already produces — a flat, indented list of every named part of a document,
//  in the order a person reads them.
//
//  THE SENTENCE THIS EXISTS TO MAKE IMPOSSIBLE, in Mary's own words, live:
//  "I can only see the very top of DeepfakeAccountability right now (just the
//  title), so the background section is outside my window." She then called
//  `pages_body` and quoted the whole document accurately. Nothing was missing
//  but a LIST: she was holding 15,775 characters and an 800-character excerpt,
//  and the only thing the prompt said about the rest of the document was that
//  it was outside a window. A document she can name section by section is a
//  document she cannot claim to be blind to.
//
//  TWO PROPERTIES EARN ITS BUDGET, and neither is decoration:
//
//    1. THE LABELS ARE MATCHABLE. Every line is a `PassageUnit.label`
//       VERBATIM, and `PassageWidening.structuralCandidates` matches against
//       exactly that string (`fold($0.label) == wanted`, containment as the
//       fallback). So a heading she reads here is a heading `find_passage`,
//       `replace_passage` and `pages_body find:` will all resolve. A rendering
//       that prettified, truncated or re-cased a label would be handing her
//       names that nothing downstream accepts — the exact shape of the
//       `-1728` incident, where the prompt offered coordinates no primitive
//       took.
//    2. IT CLOSES THE LOOP IN MEMORY. `PagesPlugin.cachedTargetedRead` serves
//       `find:` out of the watcher's `bodyBox`, so "Background" read here and
//       asked for in the same turn costs ZERO Apple Events.
//
//  DEGRADES BY COUNTING, NEVER BY SILENT TRUNCATION. A missing heading is the
//  precise shape of the failure being fixed, so an outline that could not
//  afford every heading says how many it left out, in the text, where the
//  model reads it. Silence here would reintroduce the bug in miniature.
//
//  PURE AND HEADLESS — units in, one string out. No document, no app, no I/O.
//

import Foundation

public enum PassageOutline {

    /// The lead-in. Deliberately NEUTRAL about the noun ("it", not "this
    /// document"), because the caller has just named the thing on the line
    /// above and because the next world to want an outline reads files, not
    /// documents. One string for every world beats three that drift.
    public static let lead = "Every named part of it, in order, top to bottom — this is all of it:"

    /// Two spaces per level of nesting. Enough that a sub-heading reads as
    /// subordinate, small enough that a four-deep document does not spend its
    /// budget on whitespace.
    public static let indent = "  "

    /// The outline of `units`, at most `limit` characters.
    ///
    /// Empty when nothing has a name — a document of bare paragraphs has no
    /// structure to describe, and an empty string is how the caller knows to
    /// print nothing rather than a heading list with no headings under it.
    ///
    /// WHAT GETS DROPPED WHEN IT DOES NOT FIT, and why that direction: the
    /// keep-order is SHALLOWEST FIRST, document order inside a rank. A person
    /// asking for "the background section" names a top-level heading; the
    /// sub-heading three levels down is a refinement of something already
    /// listed. Dropping from the end of the document instead would leave the
    /// tail of a long document unnamed, which is the failure being repaired,
    /// pointed the other way.
    public static func render(units: [PassageUnit], limit: Int) -> String {
        let named = units.filter { !$0.label.isEmpty }
        guard !named.isEmpty, limit > lead.count else { return "" }

        // Depth comes from the RANK of the level among the levels actually
        // present, not from `level` itself. `PagesStructure.level` hands out 0
        // for an all-caps banner, 1 for an ordinary heading and N for "5.2.1",
        // so a document with only banners and numbered headings would indent
        // its second tier by two stops with nothing at the first.
        let ranks = Set(named.map(\.level)).sorted()
        let lines = named.map { unit -> String in
            let depth = ranks.firstIndex(of: unit.level) ?? 0
            return "\n" + String(repeating: indent, count: depth) + unit.label
        }

        // Priority: shallowest first, document order inside a rank. `popLast`
        // therefore drops the deepest, latest heading — the least likely one
        // for a person to say out loud.
        var keeping = named.indices.sorted {
            named[$0].level != named[$1].level
                ? named[$0].level < named[$1].level
                : $0 < $1
        }
        var length = lines.reduce(lead.count) { $0 + $1.count }
        var dropped = 0
        // Terminates: every pass either exits or removes one element from
        // `keeping`, and the note grows by at most one character (a digit)
        // for every line's worth of characters it frees.
        while length + note(dropped).count > limit, let last = keeping.popLast() {
            length -= lines[last].count
            dropped += 1
        }
        guard !keeping.isEmpty else { return "" }

        let kept = Set(keeping)
        var text = lead
        for index in named.indices where kept.contains(index) { text += lines[index] }
        return text + note(dropped)
    }

    /// WHAT WAS LEFT OUT, said in the outline itself. Never "" for a non-zero
    /// count: an outline that quietly stops is read as a complete list, and a
    /// complete list that is missing the heading the user is about to name is
    /// exactly how "that section isn't in your document" gets said with
    /// confidence.
    public static func note(_ dropped: Int) -> String {
        guard dropped > 0 else { return "" }
        return "\n(+\(dropped) more headings, not listed — ask for any part by name.)"
    }
}
