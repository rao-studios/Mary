import Granite
import SwiftUI
import MaryRuntime

extension Home {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            var showSettings: Bool = false
            /// The totems split (the knowledge-graph store, and what
            /// retrieval did with it). Transient and separate like the three
            /// panes below. The servers control room this flag used to
            /// present now opens from inside the pane's header — server.rack
            /// keeps one meaning, and it moved with the sheet.
            var showTotems: Bool = false
            var showAbilityRuns: Bool = false
            /// The debugger split (Mary's eyes). Transient by design — a
            /// debugging affordance the user opens deliberately, not worth
            /// ConfigService's 5-point persistence ceremony.
            var showDebugger: Bool = false
            /// The routes split (the AmbientEngine's decisions). Transient
            /// for the same reason as `showDebugger`, and a SEPARATE flag
            /// rather than a shared enum so both panes can be open at once —
            /// a route changes which world leads, and the eyes are where you
            /// see what that did.
            var showRouter: Bool = false
            /// The corpus split (what indexing ingested and concluded).
            /// Transient and separate for the same reasons as the two above —
            /// you want it open BESIDE the routes while checking whether what
            /// Mary learned is what she should have learned.
            var showCorpus: Bool = false
        }

        @Store public var state: State
    }
}
