import Granite
import SwiftUI

/// Minimap of every window Mary can (and can't) see. Screenshot = perception bug report.
/// IN: Home+View split. OUT: Debugger+View. Fresh Center on insert (not root).
struct Debugger: GraniteComponent {
    @Command var center: Center
}
