//
//  AXFrameProjection.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE ONE PLACE `CGRect` BECOMES `AXFrame` AND BACK. `AXFrame`
//  (`MaryFoundation/Core/AXFrame.swift`) carries no CoreGraphics — the
//  schema layer's own "pure data" rule — so every conversion needed to fill
//  one lives here instead, where AXEngine already imports CoreGraphics
//  freely for its own CGRect algebra.
//
//  PURE GEOMETRY ONLY. This file does not know what an element IS — no
//  identity, no humanized kind word. Those come from `PageElementResolver`/
//  `PageElementKindDerivation` in `Shared/`, and AXEngine may not depend on
//  Shared/ (the one-way rule `Web/WebAreaLocator.swift`'s header states).
//  `AmbientSurfaceBridge.swift` (Shared) is where an `AXScreenElement`
//  becomes a full `AXElementRecord` — it calls here for the geometry half
//  and supplies identity/kind itself.
//
//  AX GLOBAL TOP-LEFT NEEDS NO FLIP TO REACH CG DISPLAY SPACE. AX's own
//  reporting convention IS CoreGraphics' display-space convention —
//  `CGDisplayBounds` answers in the same top-left-origin space a walked
//  frame already is. The one flip this codebase needs (`AXDesktopPlane`'s
//  header) is Cocoa's BOTTOM-left `NSScreen.frame`, which this file never
//  touches — `AXDisplayRoster` reads displays via `CGDisplayBounds`
//  specifically to avoid needing it.
//

import ApplicationServices
import CoreGraphics
import Foundation

public enum AXFrameProjection {

    /// The engine's own displays, in CG display space — the same space AX
    /// reports in, so no flip is needed anywhere in this file. Order is
    /// `CGGetActiveDisplayList`'s own (main display first is NOT guaranteed;
    /// callers wanting "the primary screen" should not assume index 0).
    public static func activeScreens() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// One rect, projected into a self-describing frame. `window` fills
    /// `inWindow` (nil when the rect itself IS the window, or when no
    /// window rect was available); `screens` fills `screen` (empty when the
    /// caller had no roster — never a claim the element is off-screen).
    public static func frame(
        _ rect: CGRect,
        inWindow window: CGRect? = nil,
        screens: [CGRect] = [],
        isClipped: Bool = false,
        capturedAt: Date
    ) -> AXFrame {
        let inWindow: AXFrameRect? = window.map {
            AXFrameRect(
                x: rect.origin.x - $0.origin.x, y: rect.origin.y - $0.origin.y,
                width: rect.width, height: rect.height)
        }
        let screen: AXFrameScreen? = screenIndex(for: rect, in: screens).map {
            AXFrameScreen(index: $0, rect: axRect(screens[$0]))
        }
        return AXFrame(
            space: .axGlobalTopLeft,
            rect: axRect(rect),
            center: AXFramePoint(x: rect.midX, y: rect.midY),
            inWindow: inWindow,
            screen: screen,
            isClipped: isClipped,
            capturedAt: capturedAt)
    }

    /// Which screen a rect belongs to: the one containing its centre, else
    /// the one it overlaps most (a window straddling two displays), else
    /// nil — never a guess when the roster is empty or nothing overlaps.
    static func screenIndex(for rect: CGRect, in screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = screens.firstIndex(where: { $0.contains(center) }) {
            return containing
        }
        let overlaps = screens.enumerated().map { index, screen in
            (index, screen.intersection(rect).width * screen.intersection(rect).height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    private static func axRect(_ rect: CGRect) -> AXFrameRect {
        AXFrameRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    // MARK: - JSON

    /// The house encoder settings, verbatim (`AbilityPackageCodec.swift`):
    /// sorted keys, no escaped slashes, ISO-8601 dates, a trailing newline
    /// when pretty-printed. Nil only on an encoding failure — a record built
    /// from finite geometry never produces one.
    public static func json(_ record: AXElementRecord, prettyPrinted: Bool = true) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return nil }
        if prettyPrinted { data.append(0x0A) }
        return String(data: data, encoding: .utf8)
    }
}
