//
//  RunningRoutineRow.swift
//  MaryRuntime
//
//  ONE PIECE OF BACKGROUND WORK, NAMED.
//
//  The status bar reported "5 running" and nothing else. The number was
//  correct and unusable: a person could see that Mary was busy five times over
//  and had no way to learn what any of the five were, how long one had been
//  going, or how to stop the one that had clearly wedged. The only stop was
//  saying "stop", which killed all five.
//
//  The brain has held everything needed for this the whole time — the routine
//  registry is keyed by id and each entry carries a spoken `label` composed
//  for the busy note. It simply never left the brain.
//

import Foundation

package struct RunningRoutineRow: Identifiable, Equatable, Sendable, Codable {
    /// The routine's own id — what a Stop control sends back to the brain.
    package var id: UUID
    /// Its spoken name ("the Purpose section"), composed at detach.
    package var label: String
    /// The exchange it belongs to, so a row can point at its own bubble.
    package var originTurnID: UUID
    /// When the app learned of it. Deliberately NOT the lane's spawn instant:
    /// the brain measures from spawn for its progress marks, and a second
    /// clock claiming to be the same one would drift against it in the UI. All
    /// this needs to answer is "how long have I been looking at this row".
    package var noticedAt: Date

    package init(id: UUID, label: String, originTurnID: UUID, noticedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.originTurnID = originTurnID
        self.noticedAt = noticedAt
    }

    /// "12s" / "4m" — coarse on purpose. A ticking seconds counter on five
    /// rows is a distraction, and the question the row answers is "has this
    /// been going a worryingly long time", which minutes answer fine.
    package var elapsed: String {
        let seconds = max(0, Int(Date().timeIntervalSince(noticedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}
