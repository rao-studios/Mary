import Granite
import SwiftUI

/// AmbientEngine decisions: classification, deciding signal, worlds, prompt cost.
/// IN: Home+View split (sibling of Debugger). OUT: Router+View.
struct Router: GraniteComponent {
    @Command var center: Center
}
