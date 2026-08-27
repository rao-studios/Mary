import Granite
import SwiftUI

/// The AmbientEngine, made visible: what each turn was classified as, which
/// signal decided it, which worlds it reached, and what that cost in prompt
/// characters and exposed Skill schemas. A screenshot of this pane is a complete
/// routing bug report.
///
/// The THIRD GraniteComponent in the app, and the sibling of `Debugger` in
/// every respect: a conditional child of Home's split, click-scoped state in
/// its Center, realtime polling in a view model the plain view owns.
///
/// It sits beside the eyes deliberately. The route decides which world leads,
/// and the lead decides what the watchers' contributions are allowed to say —
/// so "why did she answer about the wrong document?" is a question you have to
/// read on both panes at once.
struct Router: GraniteComponent {
    @Command var center: Center
}
