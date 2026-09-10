import Granite
import SwiftUI

extension Corpus {
    struct Center: GraniteCenter {
        struct State: GraniteState {
            /// Raw String rather than the enum, for the same Codable
            /// tolerance the Router's `intentFilter` keeps.
            var tab: String = CorpusTab.units.rawValue
            var selectedUnitKey: String? = nil
            var selectedProjectID: String? = nil
            /// The Schema tab's visual/raw toggle, and which subject's raw
            /// bytes are on screen. Click-scoped, like everything else here.
            var showsRawSchema: Bool = false
            var selectedSubject: String? = nil
        }

        // Transient Center; 1 Hz poll stays off @Store (200 ms debounce).
        @Store public var state: State
    }
}

enum CorpusTab: String, CaseIterable, Identifiable {
    case units
    case profile
    case schema
    case operations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .units: return "Units"
        case .profile: return "Profile"
        case .schema: return "Schema"
        case .operations: return "Activity"
        }
    }
}
