import Granite
import SwiftUI
import MaryRuntime

extension Home {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            var showSettings: Bool = false
            /// Totems split. Transient, like the panes below.
            var showTotems: Bool = false
            /// Servers sheet (same shape as Settings). Totems header has a second door.
            var showServers: Bool = false
            /// Debugger split. Transient — not ConfigService persistence.
            var showDebugger: Bool = false
            /// Routes split. Separate flag so Debugger and Router can both be open.
            var showRouter: Bool = false
            /// Corpus split. Transient like the panes above.
            var showCorpus: Bool = false
        }

        @Store public var state: State
    }
}
