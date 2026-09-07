import Granite
import SwiftUI

extension Threads: View {
    var view: some View {
        ThreadsPaneView(
            tab: _state.tab,
            selectedNodeID: _state.selectedNodeID,
            laneFilter: _state.laneFilter,
            selectedGroupID: _state.selectedGroupID,
            selectedDocumentID: _state.selectedDocumentID,
            graphSeed: _state.graphSeed,
            graphKindFilter: _state.graphKindFilter,
            graphHops: _state.graphHops,
            graphIncludesDocuments: _state.graphIncludesDocuments,
            selectedEntityID: _state.selectedEntityID,
            selectedUnitKey: _state.selectedUnitKey,
            selectedExchangeID: _state.selectedExchangeID)
    }
}
