import Granite
import SwiftUI

extension Router: View {
    var view: some View {
        // Granite-state writes stay at the component boundary (Home's
        // `_state` binding pattern); the 1 Hz trace poll lives in the pane's
        // own view model.
        RouterPaneView(
            selectedTraceID: _state.selectedTraceID,
            intentFilter: _state.intentFilter)
    }
}
