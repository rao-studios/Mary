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

        // Transient (no persist:) like Home and Debugger — click-scoped state
        // only. The 1 Hz trace poll NEVER routes through here: Granite's
        // @Store debounces 200 ms, and the realtime repaint belongs to
        // RouteTraceViewModel (the ConversationStreamViewModel doctrine).
        @Store public var state: State
    }
}
