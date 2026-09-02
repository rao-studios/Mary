//
//  AwarenessBrief.swift
//  MaryPlugin
//
//  WHAT: What a trace reads like — standing (every turn) and asked (this turn).
//  IN:   EnclosingUnit / TraceHit
//  OUT:  AwarenessObserver.promptContribution / AwarenessAdapter summaries
//  PIN:  BEARINGS, NOT PROSE. This renders facts and their file:line so the
//        model can say what a thing IS; the sentences about how to speak them
//        belong to PromptCatalog, which is the only place that writes persona.
//

import Foundation

public enum AwarenessBrief {

    /// The standing block: small enough to carry every turn, specific enough
    /// to be worth carrying.
    public static let standingBudget = 900
    /// The asked block: what one question is worth.
    public static let surroundingsBudget = 2400

    /// One traced line — "readBuffer — CodeSurfaceAdapter.swift:132: guard let …".
    public static func line(_ hit: TraceHit) -> String {
        let where_ = "\(hit.relativePath):\(hit.line)"
        guard let enclosing = hit.enclosing, !enclosing.isEmpty else {
            return "- \(where_): \(hit.snippet)"
        }
        return "- \(enclosing) — \(where_): \(hit.snippet)"
    }

    /// The standing brief the observer keeps: what the unit IS, and its
    /// bearings. Never the unit's body — the caret window already carries the
    /// text, and repeating it would spend the live section twice.
    public static func standing(
        unit: EnclosingUnit,
        fileName: String,
        callers: [TraceHit],
        callees: [TraceHit],
        /// Whether the walk that produced these actually finished. A partial
        /// walk may not say "nothing reaches it" — it did not look everywhere.
        complete: Bool = true
    ) -> String {
        var lines = [
            "Around what they are working on (traced from the project on disk):",
            "In \(fileName), \(unit.display) — lines \(unit.startLine) to \(unit.endLine).",
        ]
        if unit.chain.count > 1 {
            lines.append("Inside \(unit.scope).")
        }
        if callers.isEmpty {
            if complete {
                lines.append("Nothing else in the project reaches it that I can see.")
            }
        } else {
            lines.append("Reached from:")
            lines.append(contentsOf: callers.map(line))
        }
        if !callees.isEmpty {
            lines.append("It reaches:")
            lines.append(contentsOf: callees.map(line))
        }
        return clipped(lines.joined(separator: "\n"), to: standingBudget)
    }

    /// The asked block: the same bearings, plus wherever the words landed.
    public static func surroundings(
        unit: EnclosingUnit?,
        fileName: String?,
        callers: [TraceHit],
        callees: [TraceHit],
        matches: [TraceHit],
        query: String?
    ) -> String? {
        var lines: [String] = []
        if let unit {
            let place = fileName.map { "\($0), " } ?? ""
            lines.append("\(unit.display) — \(place)lines \(unit.startLine) to \(unit.endLine).")
        }
        if !callers.isEmpty {
            lines.append("Reached from:")
            lines.append(contentsOf: callers.map(line))
        }
        if !callees.isEmpty {
            lines.append("It reaches:")
            lines.append(contentsOf: callees.map(line))
        }
        if !matches.isEmpty {
            let about = query.map { " for \"\($0)\"" } ?? ""
            lines.append("Elsewhere in the project\(about):")
            lines.append(contentsOf: matches.map(line))
        }
        // A unit line alone is a receipt, not evidence — say nothing instead.
        guard callers.count + callees.count + matches.count > 0 else { return nil }
        return clipped(lines.joined(separator: "\n"), to: surroundingsBudget)
    }

    /// Whole lines only: a bearing cut mid-path is worse than one fewer.
    static func clipped(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        var kept: [String] = []
        var spent = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.count + 1
            guard spent + cost <= budget else { break }
            kept.append(String(line))
            spent += cost
        }
        return kept.joined(separator: "\n")
    }
}
