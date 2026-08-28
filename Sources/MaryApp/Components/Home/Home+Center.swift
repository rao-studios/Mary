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
            // NO `showCorpus`. A flag stood here for the corpus split — what
            // indexing ingested and concluded — and the pane that read it was
            // never ported, because the behavioural corpus lane is deferred.
            // The toolbar button survived the drop and lit up on press while
            // rendering nothing at all. It comes back with its pane.
        }

        @Store public var state: State
    }
}
