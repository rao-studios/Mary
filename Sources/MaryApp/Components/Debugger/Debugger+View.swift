import Granite
import SwiftUI

extension Debugger: View {
    var view: some View {
        // Granite-state writes stay at the component boundary (Home's
        // `_state` binding pattern); everything at 1–2 Hz lives in the
        // pane's own view models.
        DebuggerPaneView(
            selectedWindowID: _state.selectedWindowID,
            selectedWorld: _state.selectedWorld,
            filterToken: _state.filterToken,
            captureScopeToken: _state.captureScopeToken)
    }
}
