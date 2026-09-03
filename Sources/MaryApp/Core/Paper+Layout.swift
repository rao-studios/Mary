//
//  Paper+Layout.swift
//  Mary
//
//  WHAT: Size tokens, layout class, and the window/sheet/column primitives
//        every view resizes through.
//  OUT:  MaryApp.swift (scenes); any column, sheet or popover in MaryApp.
//  PIN:  Numbers live here, not in views — LayoutDisciplineTests fails a
//        literal `.frame(width:)`/`.frame(minWidth:)` of `atom` or more
//        found anywhere else, and checks the inequalities below hold.
//

import AppKit
import SwiftUI

/// Structure comes from a width budget (which columns exist); this is
/// density only (gutters, captions, caps). Thresholds sit strictly above
/// both window floors, so a class change can never raise a minimum.
enum MaryLayoutClass: Equatable {
    case compact, regular, wide

    init(width: CGFloat) {
        if width < Paper.Layout.regularWidth { self = .compact }
        else if width < Paper.Layout.wideWidth { self = .regular }
        else { self = .wide }
    }
}

extension Paper {
    enum Layout {
        /// A column's floor, resting width, and ceiling. `max == .infinity`
        /// marks a column that should take whatever the window has left.
        struct Span {
            let min: CGFloat
            let ideal: CGFloat
            let max: CGFloat
        }

        // Windows (content sizes — what `.maryWindow(floor:)` guarantees).
        static let homeFloor = CGSize(width: 720, height: 520)
        static let studioFloor = CGSize(width: 960, height: 600)
        static let homeDefault = CGSize(width: 1100, height: 760)
        static let studioDefault = CGSize(width: 1240, height: 800)
        static let screenMargin = CGSize(width: 80, height: 60)
        static let regularWidth: CGFloat = 1100
        static let wideWidth: CGFloat = 1440

        // Home.
        static let conversation = Span(min: 396, ideal: 520, max: .infinity)
        static let sidePane = Span(min: 300, ideal: 380, max: 640)
        static let splitAllowance: CGFloat = 10

        // Ability Studio.
        static let rail = Span(min: 200, ideal: 268, max: 300)
        static let column = Span(min: 320, ideal: 420, max: 520)
        static let studioMain = Span(min: 320, ideal: 560, max: .infinity)
        static let drawer = Span(min: 260, ideal: 320, max: 360)
        static let dualPanelWidth: CGFloat = 1200
        static let tuneCap: [MaryLayoutClass: CGFloat] = [.compact: 200, .regular: 280, .wide: 340]

        // Sheets and popovers.
        static let sheetFloor = CGSize(width: 400, height: 320)
        static let sheetMargin = CGSize(width: 80, height: 72)
        static let popover = Span(min: 260, ideal: 320, max: 360)
        static let popoverMaxHeight: CGFloat = 360
        static let labelColumn: CGFloat = 150

        /// The line between an atom (icon, divider, gutter) and a column
        /// pretending to be one. `LayoutDisciplineTests` fails any literal
        /// `.frame` width/height at or above this outside its allow-list.
        static let atom: CGFloat = 160

        /// Ideal size capped to the visible screen, so a first launch never
        /// opens off screen. Only honoured when there is no autosaved frame
        /// for the scene — a restored frame is AppKit's, not ours.
        static func fittedDefaultSize(_ ideal: CGSize) -> CGSize {
            guard let visible = NSScreen.main?.visibleFrame.size else { return ideal }
            return CGSize(
                width: min(ideal.width, visible.width - screenMargin.width),
                height: min(ideal.height, visible.height - screenMargin.height))
        }
    }
}

/// A column's declared span, handed to `MaryColumns` directly.
///
/// PIN: measuring a child three times per pass to rediscover numbers it was
/// just given is what made window resizing crawl — the "can this grow?" probe
/// laid the Skills bench out at a million points wide, twice per layout pass.
/// A `LayoutValueKey` costs nothing and is exact.
struct MaryColumnSpan: LayoutValueKey {
    static let defaultValue: Paper.Layout.Span? = nil
}

extension EnvironmentValues {
    /// Density only — see the type's doc comment.
    @Entry var maryLayoutClass: MaryLayoutClass = .regular
    /// `.zero` means unmeasured; consumers fall back to the window's floor.
    @Entry var maryWindowSize: CGSize = .zero
}

/// The one place a window's minimum is written. Measures the content size
/// once and publishes it plus the layout class; nothing downstream measures
/// the window itself. `onGeometryChange` sits outside the min-only `.frame`
/// so it reads the window's actual content size, not the bare floor.
private struct MaryWindowRoot: ViewModifier {
    let floor: CGSize
    @State private var measured: CGSize = .zero

    func body(content: Content) -> some View {
        let size = measured == .zero ? floor : measured
        content
            .environment(\.maryWindowSize, size)
            .environment(\.maryLayoutClass, MaryLayoutClass(width: size.width))
            .frame(minWidth: floor.width, minHeight: floor.height)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newValue in
                measured = newValue
            }
    }
}

/// Sizes a sheet's content to the window that presented it, never past it.
/// Sheet content inherits the presenter's environment, so `\.maryWindowSize`
/// is already there.
///
/// PIN: `.presentationSizing(.fitted)` is load-bearing, not decoration. Since
/// macOS 15 a sheet's default sizing fits its content ONCE at presentation and
/// cannot be dragged, so a sheet whose opening state is narrower than its
/// design — the routing rehearsal's empty state — opened at 470pt against a
/// declared 900 and stayed there. `.fitted` is the documented opt-in that
/// honours the declared size and restores resizing.
private struct MarySheetFrame: ViewModifier {
    @Environment(\.maryWindowSize) private var window
    let ideal: CGSize
    let floor: CGSize

    /// The window's room for a sheet, or nil when the window has not been
    /// measured — then AppKit's own clamp to the parent window is the only
    /// limit, which is a truer ceiling than any number we could guess.
    private var room: CGSize? {
        guard window != .zero else { return nil }
        return CGSize(
            width: max(floor.width, window.width - Paper.Layout.sheetMargin.width),
            height: max(floor.height, window.height - Paper.Layout.sheetMargin.height))
    }

    func body(content: Content) -> some View {
        let room = room
        content
            .frame(
                minWidth: floor.width,
                idealWidth: min(ideal.width, room?.width ?? ideal.width),
                maxWidth: room?.width ?? .infinity,
                minHeight: floor.height,
                idealHeight: min(ideal.height, room?.height ?? ideal.height),
                maxHeight: room?.height ?? .infinity)
            .presentationSizing(.fitted)
    }
}

extension View {
    /// Declares a window's constant floor and publishes its measured size
    /// and layout class. Apply once, at the scene's root view.
    func maryWindow(floor: CGSize) -> some View {
        modifier(MaryWindowRoot(floor: floor))
    }

    /// A column that flexes between a floor and a ceiling instead of a fixed
    /// literal — the shape `LayoutDisciplineTests` requires of anything
    /// `Paper.Layout.atom` or wider.
    func maryColumn(_ span: Paper.Layout.Span) -> some View {
        frame(minWidth: span.min, idealWidth: span.ideal, maxWidth: span.max)
            .layoutValue(key: MaryColumnSpan.self, value: span)
    }

    /// A sheet root that never exceeds the window that presented it.
    func marySheet(ideal: CGSize, floor: CGSize = Paper.Layout.sheetFloor) -> some View {
        modifier(MarySheetFrame(ideal: ideal, floor: floor))
    }

    /// A popover that never grows past the kit's popover span.
    func maryPopover() -> some View {
        maryColumn(Paper.Layout.popover)
            .frame(maxHeight: Paper.Layout.popoverMaxHeight)
    }
}
