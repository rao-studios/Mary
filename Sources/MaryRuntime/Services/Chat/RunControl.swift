//
//  RunControl.swift
//  MaryRuntime
//
//  WHAT: UI stop door — three fire-and-forget verbs into MaryBrain.
//  IN:   SwiftUI Stop controls (must not `await MaryRuntime.brain` in a body)
//  OUT:  brain.stopRoutine / stopAllRoutines / stopRun
//  PIN:  Stop is a request; the chip updates when the event channel settles.
//

import Foundation
import MaryBrain

package enum RunControl {

    /// Stop one detached routine — the Stop on one running-list row.
    package static func stopRoutine(id: UUID) {
        Task { await MaryRuntime.brain.stopRoutine(id: id) }
    }

    /// Stop every background routine, paused typing included.
    package static func stopAll() {
        Task { await MaryRuntime.brain.stopAllRoutines() }
    }

    /// Stop one in-flight call by the id its chip shows. Lane continues.
    /// Settled-call cancel is a no-op.
    package static func stopRun(id: String) {
        Task { await MaryRuntime.brain.stopRun(id: id) }
    }
}
