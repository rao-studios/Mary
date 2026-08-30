import Granite
import SwiftUI

extension Router {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            /// Which trace row is expanded — written on row tap. Raw String
            /// (the record's UUID) for the same GraniteState Codable
            /// tolerance as Debugger's `selectedWorld`.
            var selectedTraceID: String? = nil
            /// Filter to one intent, as `AmbientIntent.rawValue`; nil = all.
            var intentFilter: String? = nil
        }

        // Transient Center; 1 Hz trace lives in RouteTraceViewModel.
        @Store public var state: State
    }
}
