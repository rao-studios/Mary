import Granite
import SwiftUI

/// Mary's eyes, made visible: the minimap of every window Mary can (and
/// can't) see, with what the watchers actually parsed overlaid on each tile.
/// A screenshot of this pane is a complete perception bug report.
///
/// The second GraniteComponent in the app, embedded as a conditional child of
/// Home's split — Granite components are plain Views (`@Command` rides a
/// `@StateObject`), so insertion builds a fresh center and removal tears it
/// down; nothing here assumes root-ness.
struct Debugger: GraniteComponent {
    @Command var center: Center
}
