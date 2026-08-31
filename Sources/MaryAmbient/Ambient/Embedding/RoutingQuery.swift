//
//  RoutingQuery.swift
//  MaryAmbient
//
//  WHAT: One string the embedding indexes vectorize for a turn.
//  IN:   utterance + live world digest + recent user turns
//  OUT:  SemanticIntentIndex / ability / skill search
//  PIN:  Fact ranking still uses the raw utterance; this string is embeddings only.
//

import Foundation

public enum RoutingQuery {

    public struct World: Sendable, Equatable {
        public var leadApplicationID: String?
        public var leadTitle: String?
        public var frontmostApplicationID: String?
        public var playerRunning: Bool
        public var playerName: String?
        public var selectionSubject: String?
        public var leadFact: String?

        public init(
            leadApplicationID: String? = nil,
            leadTitle: String? = nil,
            frontmostApplicationID: String? = nil,
            playerRunning: Bool = false,
            playerName: String? = nil,
            selectionSubject: String? = nil,
            leadFact: String? = nil
        ) {
            self.leadApplicationID = leadApplicationID
            self.leadTitle = leadTitle
            self.frontmostApplicationID = frontmostApplicationID
            self.playerRunning = playerRunning
            self.playerName = playerName
            self.selectionSubject = selectionSubject
            self.leadFact = leadFact
        }

        public var isEmpty: Bool {
            leadApplicationID == nil
                && leadTitle == nil
                && frontmostApplicationID == nil
                && !playerRunning
                && playerName == nil
                && selectionSubject == nil
                && leadFact == nil
        }
    }

    public static let historyCap = 3
    public static let factCap = 120
    public static let turnCap = 160

    /// Utterance first, then clipped world and history lines.
    public static func compose(
        utterance: String,
        world: World? = nil,
        recentUserTurns: [String] = []
    ) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [spoken]
        if let world, !world.isEmpty {
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

    private static func worldLines(_ world: World) -> [String] {
        var lines: [String] = []
        if let title = world.leadTitle, !title.isEmpty {
            lines.append("lead: \(title)")
        } else if let id = world.leadApplicationID, !id.isEmpty {
            lines.append("lead: \(id)")
        }
        if let front = world.frontmostApplicationID, !front.isEmpty,
           front != world.leadApplicationID {
            lines.append("frontmost: \(front)")
        }
        if world.playerRunning {
            let name = world.playerName.map { " (\($0))" } ?? ""
            lines.append("player: running\(name)")
        }
        if let subject = world.selectionSubject, !subject.isEmpty {
            lines.append("selection: \(clip(subject, cap: 80))")
        }
        if let fact = world.leadFact, !fact.isEmpty {
            lines.append("fact: \(clip(fact, cap: factCap))")
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
