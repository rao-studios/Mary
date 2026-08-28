//
//  RunControl.swift
//  MaryRuntime
//
//  THE ONE DOOR THE UI KNOCKS ON TO STOP SOMETHING.
//
//  Views must not reach into the brain actor: every `await MaryRuntime.brain
//  .something()` in a SwiftUI body is another place that has to get the hop
//  right, and a Stop button is exactly the control where "it looked like it
//  worked" is worst. Three verbs, all fire-and-forget, because a stop is a
//  REQUEST — the settled record arriving through the normal event channel is
//  what actually updates the chip, not the return of this call.
//

import Foundation
import MaryBrain

package enum RunControl {

    /// Stop one detached routine — the Stop on one row of the running list.
    package static func stopRoutine(id: UUID) {
        Task { await MaryRuntime.brain.stopRoutine(id: id) }
    }

    /// Stop everything running in the background, paused typing included.
    package static func stopAll() {
        Task { await MaryRuntime.brain.stopAllRoutines() }
    }

    /// Stop one in-flight call, by the id its chip shows.
    ///
    /// The lane it belongs to keeps going: the person is objecting to one act,
    /// not to the whole request. Cancelling a call already settled is a no-op
    /// — a stop arriving a moment late is a race a person can lose honestly.
    package static func stopRun(id: String) {
        Task { await MaryRuntime.brain.stopRun(id: id) }
    }
}
