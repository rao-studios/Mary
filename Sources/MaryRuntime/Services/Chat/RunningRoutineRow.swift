//
//  RunningRoutineRow.swift
//  MaryRuntime
//
//  WHAT: One named background routine for the status bar / popover.
//  IN:   MaryBrain routine registry (id, spoken label) → ChatService.Center
//  OUT:  Stop → RunControl.stopRoutine(id)
//

import Foundation

package struct RunningRoutineRow: Identifiable, Equatable, Sendable, Codable {
    /// Routine id — what Stop sends back to the brain.
    package var id: UUID
    /// Spoken name ("the Purpose section"), composed at detach.
    package var label: String
    /// Origin exchange — so a row can point at its bubble.
    package var originTurnID: UUID
    /// When the app learned of it. Not the lane spawn instant (brain clock).
    package var noticedAt: Date

    package init(id: UUID, label: String, originTurnID: UUID, noticedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.originTurnID = originTurnID
        self.noticedAt = noticedAt
    }

    /// "12s" / "4m" — coarse; answers "has this been going too long".
    package var elapsed: String {
        let seconds = max(0, Int(Date().timeIntervalSince(noticedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}
