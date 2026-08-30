//
//  PassageOutline.swift
//  MaryBrain
//
//  WHAT: Table of contents from the units a world's structure reader already produces.
//  IN:   PassageUnit
//  OUT:  prompt. Labels match PassageWidening.structuralCandidates verbatim.
//  PIN:  Degrades by counting, never silent truncation. Pure: units in, one string out.
//
import Foundation

public enum PassageOutline {

    /// The lead-in. Deliberately NEUTRAL about the noun ("it", not "this document"), because
    /// the caller has just named the thing on the line above and because the next world to want
    /// an outline reads files, not documents.
    public static let lead = "Every named part of it, in order, top to bottom — this is all of it:"

    /// Two spaces per level of nesting. Enough that a sub-heading reads as
    /// subordinate, small enough that a four-deep document does not spend its
    /// budget on whitespace.
    public static let indent = "  "

    /// The outline of `units`, at most `limit` characters. Empty when nothing has a name — a
    /// document of bare paragraphs has no structure to describe, and an empty string is how the
    /// caller knows to print nothing rather than a heading list with no headings under it.
    public static func render(units: [PassageUnit], limit: Int) -> String {
        let named = units.filter { !$0.label.isEmpty }
        guard !named.isEmpty, limit > lead.count else { return "" }

        // Depth comes from the RANK of the level among the levels actually present, not from
        // `level` itself.
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

    /// WHAT WAS LEFT OUT, said in the outline itself.
    public static func note(_ dropped: Int) -> String {
        guard dropped > 0 else { return "" }
        return "\n(+\(dropped) more headings, not listed — ask for any part by name.)"
    }
}
