import Granite
import SwiftUI
import MaryRuntime

extension Debugger {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            /// Inspector selection — written on tile tap.
            var selectedWindowID: UInt32? = nil
            /// The inspector's target world, set at tap-time from the tile's
            /// bundle id (PerceptionWorld.rawValue — raw String keeps
            /// GraniteState Codable-tolerant).
            var selectedWorld: String? = nil
            /// The filter bar's tab, as EyesFilter's raw token: nil = All,
            /// "@eyes" = the watched set, anything else = an AppTileGroup.id
            /// (raw String for the same Codable tolerance as selectedWorld).
            /// Click-scoped, exactly like selectedWindowID — @Store's 200 ms
            /// debounce is invisible on a tab click, and the 1 Hz sweep it
            /// steers still never routes through here.
            var filterToken: String? = nil
            /// CaptureScope.rawValue — nil/unknown decodes to `.all`, the
            /// pane's pre-filter behaviour (every window kept warm).
            var captureScopeToken: String? = nil
            // No pin mirror here on purpose: pin truth lives in
            // WorkspaceFocusTracker and the pane reads it through the
            // perception view model. A Center copy died with the pane while
            // the pin kept steering focus — a badge that lies about live
            // state is worse than no badge.
        }

        // Transient (no persist:) like Home — click-scoped state only. The
        // 1 Hz minimap data NEVER routes through here: Granite's @Store
        // debounces 200 ms, and the realtime repaint belongs to
        // DebuggerMinimapViewModel (the ConversationStreamViewModel doctrine).
        @Store public var state: State
    }
}
