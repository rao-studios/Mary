//
//  AX.swift
//  MaryAmbient
//
//  WHAT: One read of one AX attribute, typed by return shape.
//  OUT:  AXSelectionReader / MaryAdapter / app AX walks
//  PIN:  Lives here because every AX-reading package already depends on MaryAmbient.
//        attribute(_:_:) stays public for raw CF types this file cannot type away.
//
import ApplicationServices
import CoreGraphics
import Foundation
import os

public enum AX {

    /// Every Accessibility round trip this process has made, when asked for.
    ///
    /// PIN: THE ROUND TRIP IS THE COST, AND WALL CLOCK CANNOT SEE IT. MEASURED
    /// on Apple Music, the SAME 729-node walk took 4.1s and 52.6s on
    /// consecutive runs of the same binary with the player paused — a 12x
    /// spread on identical work, because what is being timed is the target's
    /// AX server answering, not anything this process does. A traversal that
    /// claims to be cheaper therefore cannot prove it by being faster; it
    /// proves it by making fewer calls, which is what this counts.
    ///
    /// Off unless `MARY_AX_COUNT=1`, so the check is one static Bool on a path
    /// that is already an IPC round trip.
    public enum Accounting {
        public static let enabled =
            ProcessInfo.processInfo.environment["MARY_AX_COUNT"] == "1"

        private static let box = OSAllocatedUnfairLock<Int>(initialState: 0)

        static func note() { box.withLock { $0 += 1 } }

        /// Round trips since this process started.
        public static var reads: Int { box.withLock { $0 } }
    }

    /// The raw, untyped attribute value. `nil` on any failure, including a
    /// present-but-unreadable attribute — this file never distinguishes "absent" from "AX
    /// declined to answer" because no caller in this tree has needed to.
    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        if Accounting.enabled { Accounting.note() }
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

    /// A `CFRange`-typed attribute, decoded to a Swift `Range<Int>`.
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

    /// A CGSize-typed AXValue attribute — `frame(of:)`'s decode for attributes that carry a
    /// size alone.
    public static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let ref = attribute(element, name),
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// The element's frame, decoded from the paired `kAXPosition`/`kAXSize` attributes — the
    /// pattern four independent files (RemoteHandsStateProvider, ScreenRegionCapture,
    /// SafariWebSurface, ProbeShaderFeel) reimplemented, three of them byte-for-byte.
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

    /// One parameterized read — the `AXUIElementCopyParameterizedAttributeValue` dance named
    /// once, the sibling of `attribute(_:_:)` for the attributes that answer a question rather
    /// than describe a property.
    public static func parameterized(
        _ element: AXUIElement, _ name: String, parameter: CFTypeRef
    ) -> CFTypeRef? {
        if Accounting.enabled { Accounting.note() }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, parameter, &ref) == .success
        else { return nil }
        return ref
    }

    /// The attributed slice of a text element:
    /// `kAXAttributedStringForRangeParameterizedAttribute` over a character range.
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
