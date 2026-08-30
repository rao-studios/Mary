import Granite
import SwiftUI

extension Corpus: View {
    var view: some View {
        CorpusPaneView(
            tab: _state.tab,
            selectedUnitKey: _state.selectedUnitKey,
            selectedProjectID: _state.selectedProjectID,
            showsRawSchema: _state.showsRawSchema,
            selectedSubject: _state.selectedSubject)
    }
}
