import Granite
import SwiftUI
import MaryRuntime

extension Home {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            var showSettings: Bool = false
            /// The totems split (the knowledge-graph store, and what
            /// retrieval did with it). Transient and separate like the three
            /// panes below.
            var showTotems: Bool = false
            /// Servers control room. A sheet, not a pane — same shape as
            /// Settings. The Totems header keeps a second door so the
            /// control room still opens without hunting the nav bar.
            var showServers: Bool = false
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
            /// The corpus split — what indexing ingested and what it
            /// concluded about how you work. Transient like the three above.
            ///
            /// It was absent for a while, with a note here explaining that the
            /// pane had not been ported and that the toolbar button would light
            /// up while rendering nothing. Both are back, together, which is
            /// the only order that was ever acceptable.
            var showCorpus: Bool = false
        }

        @Store public var state: State
    }
}
