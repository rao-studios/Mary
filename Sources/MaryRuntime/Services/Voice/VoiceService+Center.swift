import Granite
import SwiftUI

/// The pipeline state as the UI reads it.
package enum VoicePhase: String, GraniteModel {
    case idle
    case listening
    case hearingYou
    case transcribing
    case thinking
    /// The user superseded the in-flight turn and is speaking a correction.
    case amending
    case speaking
}

extension VoiceService {
    package struct Center: GraniteCenter {
        package init() {}
        /// Live session state — deliberately not persisted.
        package struct State: GraniteState {
            package init() {}
            package var isSessionActive: Bool = false
            package var phase: VoicePhase = .idle
            package var audioLevel: Float = 0
            package var lastPartial: String = ""
        }

        @Event package var start: Start.Reducer
        @Event package var stop: Stop.Reducer

        @Store public var state: State
    }
}
