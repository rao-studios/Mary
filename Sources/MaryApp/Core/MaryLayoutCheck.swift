//
//  MaryLayoutCheck.swift
//  Mary
//
//  WHAT: Debug-only window sizing for the responsive-layout harness.
//  IN:   HomeSessionView.task; AbilityStudioView.onAppear.
//  OUT:  NSApp.windows — the app's one gated NSWindow use.
//  PIN:  Inert without `MARY_LAYOUT_CHECK` set. Panes/drawer directives are
//        parsed now so later phases can read them; only window sizing is
//        applied until Home's pane budget and the Studio's panel budget exist.
//
//    MARY_LAYOUT_CHECK="home:720x520;studio:960x600;panes:debugger,router;drawer;sheet:rehearsal"
//

#if DEBUG
import AppKit
import Foundation

enum MaryLayoutCheck {
    struct Directive {
        var homeSize: CGSize?
        var studioSize: CGSize?
        var panes: [String] = []
        var showsDrawer = false
        /// A sheet to open on launch, so its presented size can be measured
        /// without driving the UI — synthetic clicks do not reach these
        /// controls. "rehearsal" (Studio) or "settings" (Home).
        var sheet: String?
    }

    static let directive: Directive? = {
        guard let raw = ProcessInfo.processInfo.environment["MARY_LAYOUT_CHECK"] else { return nil }
        var result = Directive()
        for field in raw.split(separator: ";") {
            let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            switch key {
            case "home": result.homeSize = size(from: value)
            case "studio": result.studioSize = size(from: value)
            case "panes": result.panes = value.split(separator: ",").map(String.init)
            case "drawer": result.showsDrawer = true
            case "sheet": result.sheet = value
            default: break
            }
        }
        return result
    }()

    private static func size(from spec: String) -> CGSize? {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Pins the Home window (identified as whichever window is not the
    /// Studio) to the harness size, top-left of the main screen.
    static func pinHome() {
        guard let size = directive?.homeSize,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "Ability Studio" })
        else { return }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
    }

    static func pinStudio() {
        guard let size = directive?.studioSize,
              let window = NSApp.windows.first(where: { $0.title == "Ability Studio" })
        else { return }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
    }

    /// Whether the harness asked for this sheet to open on launch.
    static func opens(sheet name: String) -> Bool {
        directive?.sheet == name
    }
}
#endif
