import Granite
import SwiftUI
import MaryRuntime

extension Home {
    /// A side pane the split can show beside the conversation. Order in
    /// `Center.State.openPanes` is the user's intent, oldest first; which of
    /// these are actually on screen is a width budget — see `HomePaneBudget`.
    enum Pane: String, Codable, Hashable, CaseIterable {
        case debugger, router, threads, corpus
    }

    struct Center: GraniteCenter {
        struct State: GraniteState {
            var showSettings: Bool = false
            /// Servers sheet (same shape as Settings). Threads header has a second door.
            var showServers: Bool = false
            /// Transient, like the panes it names — not ConfigService persistence.
            var openPanes: [Pane] = []
        }

        @Store public var state: State
    }
}
