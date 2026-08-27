//
//  AX.swift
//  MaryAmbient
//
//  ONE READ OF ONE ATTRIBUTE, TYPED BY RETURN SHAPE. Every AX-touching file in
//  this tree reimplemented the same three-line dance — call
//  `AXUIElementCopyAttributeValue`, check `.success`, cast the result —
//  behind its own private wrapper: 20 near-identical wrappers across 14
//  files at last count (docs/DECOMPOSITION.md Part IV.1, H1). This is that
//  dance, named once.
//
//  Lives in MaryAmbient because it is the one layer every AX-reading
//  package already depends on (MaryAdapter, the app) —
//  MaryAmbient itself depends on MaryFoundation alone and may not reach
//  upward, so this is the only home that does not invert a standing layering
//  rule (docs/architecture/README.md, "The package layering").
//
//  `attribute(_:_:)` stays public: a caller that must inspect the raw CF type
//  itself — a value that may arrive as either `Bool` or `NSNumber`, a marker
//  range checked against `AXTextMarkerRangeGetTypeID()` — is not a case this
//  file can type away, and forcing one through a typed accessor would be
//  the wrong kind of uniformity.
//

import ApplicationServices
import CoreGraphics
import Foundation

public enum AX {

    /// The raw, untyped attribute value. `nil` on any failure, including a
    /// present-but-unreadable attribute — this file never distinguishes
    /// "absent" from "AX declined to answer" because no caller in this tree
    /// has needed to.
    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success
        else { return nil }
        return ref
    }

    /// Whether the attribute answers at all — for existence-only probes
    /// (an element "carries text" iff any of several attributes exist).
    public static func hasAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        attribute(element, name) != nil
    }

    public static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let ref = attribute(element, name),
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    public static func number(_ element: AXUIElement, _ name: String) -> NSNumber? {
        attribute(element, name) as? NSNumber
    }

    /// Unbounded — a caller walking a tree supplies its own node/depth cap;
    /// this primitive only reads what AX reports.
    public static func children(
        _ element: AXUIElement, _ name: String = kAXChildrenAttribute
    ) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    /// A `CFRange`-typed attribute, decoded to a Swift `Range<Int>`. `nil` on
    /// a negative location/length as well as on any read failure — AX has
    /// been observed to report a sentinel `{-1, -1}` for "unavailable"
    /// through this same success path, so a validated range means fully
    /// present, not merely decodable.
    public static func range(_ element: AXUIElement, _ name: String) -> Range<Int>? {
        guard let ref = attribute(element, name),
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0
        else { return nil }
        return range.location..<(range.location + range.length)
    }

    /// A CGSize-typed AXValue attribute — `frame(of:)`'s decode for
    /// attributes that carry a size alone. First consumer: the AX engine's
    /// gap scan reading `"AXContentSize"` off a scroll area (the size of what
    /// the area scrolls, which can dwarf the viewport the frame describes).
    public static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let ref = attribute(element, name),
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// The element's frame, decoded from the paired `kAXPosition`/`kAXSize`
    /// attributes — the pattern four independent files (RemoteHandsStateProvider,
    /// ScreenRegionCapture, SafariWebSurface, ProbeShaderFeel) reimplemented,
    /// three of them byte-for-byte.
    public static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = attribute(element, kAXPositionAttribute),
              let sizeRef = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// One parameterized read — the `AXUIElementCopyParameterizedAttributeValue`
    /// dance named once, the sibling of `attribute(_:_:)` for the attributes
    /// that answer a question rather than describe a property. Same contract:
    /// `nil` on any failure, "absent" never distinguished from "declined".
    public static func parameterized(
        _ element: AXUIElement, _ name: String, parameter: CFTypeRef
    ) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, parameter, &ref) == .success
        else { return nil }
        return ref
    }

    /// The attributed slice of a text element:
    /// `kAXAttributedStringForRangeParameterizedAttribute` over a character
    /// range. Attributes arrive under AX's own text keys (`AXFont`,
    /// `AXForegroundColor`, …), not AppKit's — decoding them is the caller's
    /// concern; this primitive only performs the read.
    public static func attributedString(
        _ element: AXUIElement, forRange range: Range<Int>
    ) -> NSAttributedString? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return parameterized(
            element, kAXAttributedStringForRangeParameterizedAttribute, parameter: parameter
        ) as? NSAttributedString
    }
}
