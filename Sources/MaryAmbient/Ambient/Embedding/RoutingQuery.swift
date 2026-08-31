//
//  RoutingQuery.swift
//  MaryAmbient
//
//  WHAT: One string the embedding indexes vectorize for a turn.
//  IN:   utterance + live snapshot digest + recent user turns
//  OUT:  SemanticIntentIndex / ability / skill search
//  PIN:  Fact ranking still uses the raw utterance; this string is embeddings only.
//

import Foundation

public enum RoutingQuery {

    public static let historyCap = 3
    public static let turnCap = 160

    /// Utterance first, then clipped snapshot and history lines.
    public static func compose(
        utterance: String,
        world: AmbientWorld.Snapshot? = nil,
        recentUserTurns: [String] = []
    ) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [spoken]
        if let world {
            lines.append(contentsOf: worldLines(world))
        }
        let recent = recentUserTurns
            .map { clip($0, cap: turnCap) }
            .filter { !$0.isEmpty }
            .suffix(historyCap)
        if !recent.isEmpty {
            lines.append("recent: " + recent.joined(separator: " | "))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func worldLines(_ snapshot: AmbientWorld.Snapshot) -> [String] {
        var lines: [String] = []
        let lead = snapshot.place.displayName
        if !lead.isEmpty {
            lines.append("lead: \(lead)")
        }
        if let subject = snapshot.subject ?? snapshot.selectedText,
           !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("selection: \(clip(subject, cap: 80))")
        }
        return lines
    }

    private static func clip(_ text: String, cap: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > cap else { return trimmed }
        return String(trimmed.prefix(cap))
    }

    /// The literal utterance out of a composed multi-line query — `compose`
    /// always puts it first. Measured with `MARY_EMBEDDING_CALIBRATION=1`
    /// against the real on-device model: a real sentence embedding dilutes
    /// badly once world/history lines are appended (a query that uniquely
    /// wins a Skill bare can drop below the floor once composed), so every
    /// embedding consumer scores against this, never the whole composed
    /// string. Corpus seeds are already single sentences and are unaffected.
    public static func firstLine(_ query: String) -> String {
        query.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? query
    }
}
