//
//  PageListing.swift
//  MaryPlugin
//
//  WHAT: A page read, said in the words a person would use to name one of its parts.
//  IN:   the vision roster + its map summary
//  OUT:  the summary of read_page, and the tail of every act
//  PIN:  WHAT IS SPOKEN IS WHAT RESOLVES. The number beside a row here is counted the
//        same way `SpokenReference` counts ordinals — within the kind, over the same
//        pool, in the same order — because a listing that numbers rows differently from
//        the resolver teaches the model to ask for the wrong thing and then blames it.
//        THE DIALOG COMES FIRST. Nothing behind an overlay can be reached while it is
//        up, so a listing that buries a consent wall under the page it is covering is
//        describing a page nobody can act on.
//        A GUESSED NAME IS MARKED. "button 4" is a position, not a name somebody wrote,
//        and offering it as though it were is how a model comes to believe a page said
//        something it never said.
//

import Foundation
import MaryComputerUse

/// One page read, ready to be spoken about.
public struct PageRoster: Sendable {
    public var elements: [AXScreenElement]
    public var map: PageMapSummary
    public var pageFrame: CGRect
    public var capturedAt: Date

    public init(
        elements: [AXScreenElement], map: PageMapSummary = PageMapSummary(),
        pageFrame: CGRect = .zero, capturedAt: Date = Date()
    ) {
        self.elements = elements
        self.map = map
        self.pageFrame = pageFrame
        self.capturedAt = capturedAt
    }

    /// Only what can be acted on. What a phrase is resolved against.
    public var actionable: [AXScreenElement] {
        elements.filter { element in
            guard let annotation = map.annotation(forOrdinal: element.ordinal)
            else { return element.category == .interactive }
            return annotation.affordance != .none
        }
    }

    /// Only what can be typed into.
    public var fillable: [AXScreenElement] {
        elements.filter { map.annotation(forOrdinal: $0.ordinal)?.affordance == .fill }
    }

    public var adjustable: [AXScreenElement] {
        elements.filter { map.annotation(forOrdinal: $0.ordinal)?.affordance == .adjust }
    }

    public func annotation(for element: AXScreenElement) -> SeenElementAnnotation? {
        map.annotation(forOrdinal: element.ordinal)
    }
}

public enum PageListing {

    /// How many rows a listing names before it stops. A list nobody can hold is not an
    /// offer — the same reason the affordance nudge names three.
    public static let defaultLimit = 10
    /// A tail sits inside another sentence, so it is shorter still.
    public static let tailLimit = 5
    public static let tailCharacterLimit = 220

    /// The page, listed.
    public static func spoken(
        _ roster: PageRoster,
        pageName: String?,
        query: String? = nil,
        limit: Int = defaultLimit
    ) -> String {
        let rows = filtered(roster, query: query)
        guard !rows.isEmpty else {
            let named = query.map { " matching \"\($0)\"" } ?? ""
            return "I can see the page\(pageName.map { " — \($0)" } ?? ""), but nothing on it\(named) that I can act on."
        }

        var lines: [String] = []
        if let overlay = roster.map.overlay, query == nil {
            let inside = roster.elements
                .filter { overlay.memberOrdinals.contains($0.ordinal) }
                .filter { roster.annotation(for: $0)?.affordance != SeenAffordance.none }
                .prefix(3)
                .map { "\"\(ScreenElementResolver.shortened($0.label, limit: 40))\"" }
            if !inside.isEmpty {
                lines.append(
                    "Something is covering the page: \(SpokenReference.spokenList(Array(inside))).")
            }
        }

        let head = pageName.map { "On \($0), " } ?? ""
        lines.append("\(head)\(offeringSentence(rows))")
        lines.append(contentsOf: numbered(rows, roster: roster, limit: limit))
        if rows.count > limit {
            lines.append("…and \(rows.count - limit) more.")
        }
        return lines.joined(separator: "\n")
    }

    /// The same, compressed to ride along at the end of an act's own sentence.
    /// How much of a page's prose one question is worth. `AwarenessBrief`'s
    /// asked-block budget, for the same reason: a passage, not a document.
    public static let textBudget = 2400

    /// WHAT THE PAGE SAYS, top to bottom.
    ///
    /// PIN: THE ROWS THE ACTING LISTING THROWS AWAY. `spoken` and `tail` render
    /// what can be PRESSED — the text rows are furniture to them. To a question
    /// about the page they are the entire answer, so this reads the same roster
    /// the other way round. Reading order is the roster's own order, which the
    /// reading already put in reading order.
    /// DUPLICATES COLLAPSE. The page reader emits some elements twice (once for
    /// an outer link, once for the text inside it) — measured, pervasive, and
    /// harmless to a listing that numbers rows but absurd in a passage, which
    /// would say everything twice.
    public static func text(
        _ roster: PageRoster, pageName: String?, budget: Int = textBudget
    ) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for element in roster.elements {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count > 1 else { continue }
            let key = SpokenReference.normalized(label)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            lines.append(label)
        }
        guard !lines.isEmpty else {
            return pageName.map { "I can read nothing on \($0)." }
                ?? "I can read nothing on this page."
        }
        var passage = pageName.map { "The visible part of \($0), top to bottom:" }
            ?? "The visible part of the page, top to bottom:"
        for line in lines {
            guard passage.count + line.count + 1 <= budget else { break }
            passage += "\n" + line
        }
        return passage
    }

    public static func tail(_ roster: PageRoster, limit: Int = tailLimit) -> String {
        let rows = filtered(roster, query: nil)
        guard !rows.isEmpty else { return "" }
        let named = numbered(rows, roster: roster, limit: limit)
            .joined(separator: "; ")
        let sentence = "Now offering \(offeringSentence(rows)) — \(named)"
        guard sentence.count > tailCharacterLimit else { return sentence }
        return String(sentence.prefix(tailCharacterLimit - 1)) + "…"
    }

    /// "4 videos, 2 links and a field".
    static func offeringSentence(_ rows: [AXScreenElement]) -> String {
        let offerings = ScreenElementResolver.offerings(in: rows)
        guard !offerings.isEmpty else { return "\(rows.count) things" }
        let named = offerings.prefix(4).map { offering -> String in
            offering.count == 1
                ? "1 \(offering.kind.spokenWord)"
                : "\(offering.count) \(offering.kind.spokenWord)s"
        }
        return SpokenReference.spokenList(Array(named))
    }

    /// Rows, numbered WITHIN THEIR KIND — the way they will be asked for.
    static func numbered(
        _ rows: [AXScreenElement], roster: PageRoster, limit: Int
    ) -> [String] {
        var counts: [PageElementKind: Int] = [:]
        var lines: [String] = []
        for row in rows {
            let kind = row.spokenKind ?? .link
            counts[kind, default: 0] += 1
            guard lines.count < limit else { continue }
            let annotation = roster.annotation(for: row)
            let label = ScreenElementResolver.shortened(row.label, limit: 60)
            var line = "\(kind.spokenWord) \(counts[kind] ?? 1) — \(label)"
            if let group = row.containerTrail.first, !group.isEmpty, group != "band" {
                line += " (\(group))"
            }
            if annotation?.labelSource.isReal == false {
                // SAID PLAINLY. Nothing wrote this name; it is where the thing is.
                line += " (unnamed)"
            }
            if let hints = annotation?.hints, !hints.isEmpty {
                line += " [\(hints.joined(separator: ", "))]"
            }
            if !row.isEnabled { line += " (unavailable)" }
            lines.append(line)
        }
        return lines
    }

    /// A query narrows the listing the same way it would narrow a resolve.
    static func filtered(_ roster: PageRoster, query: String?) -> [AXScreenElement] {
        let rows = roster.actionable
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
        let folded = SpokenReference.normalized(query)
        guard !folded.isEmpty else { return rows }
        let words = folded.split(separator: " ").map(String.init)
        let matching = rows.filter { row in
            let label = SpokenReference.normalized(row.label)
            return words.allSatisfy { label.contains($0) }
        }
        // A QUERY THAT MATCHES NOTHING STILL SHOWS THE PAGE. Answering "nothing here"
        // when the page is full of things is a worse answer than showing them.
        return matching.isEmpty ? rows : matching
    }
}
