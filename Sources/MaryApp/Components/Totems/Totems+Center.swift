import Granite
import SwiftUI

extension Totems {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            /// Raw String rather than the enum, for the same Codable
            /// tolerance the Router's `intentFilter` keeps.
            var tab: String = TotemsTab.nodes.rawValue
            var selectedNodeID: String? = nil
            var laneFilter: String? = nil
            var selectedGroupID: String? = nil
            var selectedDocumentID: String? = nil
            /// Graph controls are commit-scoped: the seed TextField stages
            /// keystrokes in view-local @State (the 200 ms debounce below
            /// would blur typing) and lands here only on submit.
            var graphSeed: String = ""
            var graphKindFilter: String? = nil
            var graphHops: Int = 1
            var graphIncludesDocuments: Bool = false
            var selectedEntityID: String? = nil
            var selectedUnitKey: String? = nil
            var selectedExchangeID: String? = nil
        }

        // Transient Center; 1 Hz retrieval poll stays off @Store.
        @Store public var state: State
    }
}

enum TotemsTab: String, CaseIterable, Identifiable {
    case nodes
    case library
    case graph
    case ledger
    case retrieval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodes: return "Nodes"
        case .library: return "Library"
        case .graph: return "Graph"
        case .ledger: return "Ledger"
        case .retrieval: return "Retrieval"
        }
    }
}
