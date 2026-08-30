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
            /// Filter tab token: nil = All, "@eyes" = watched, else AppTileGroup.id.
            var filterToken: String? = nil
            /// CaptureScope.rawValue — nil/unknown decodes to `.all`, the
            /// pane's pre-filter behaviour (every window kept warm).
            var captureScopeToken: String? = nil
            // Pin truth is WorkspaceFocusTracker via the perception VM.
        }

        // Transient Center; 1 Hz minimap lives in DebuggerMinimapViewModel.
        @Store public var state: State
    }
}
