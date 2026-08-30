//
//  ProseSurfaceAX.swift
//  MaryPlugin
//
//  READING AND WRITING AN APPLICATION'S TEXT THROUGH ACCESSIBILITY — with no
//  application named anywhere in this file.
//
//  This is the compiled half of the prose-surface lane. It knows how to walk a
//  window to a text element, read the whole string out of it, select a range
//  and replace that selection. What it does NOT know is which role to descend
//  to, how a document is identified, or which chord makes a new one: a
//  package declares those in its `proseSurface` block and they arrive here as
//  a `ProseSurfaceRegistration`.
//
//  THE FAMILY THIS SERVES, stated precisely, because the boundary is real and
//  was learned expensively. An AppKit editor that exposes its whole document
//  through ONE text element — a stock `NSTextView`, which is what TextEdit is
//  — reads and writes correctly here. A PAGE-PARTITIONED editor does not:
//  Bonnie demoted exactly this write path to a fallback for Pages after
//  measuring the failure, and its note is worth carrying because the shape
//  repeats. Pages models a document as pages (3,635 characters on page one,
//  1,627 on page two, measured), its accessibility layer is a canvas tree, and
//  two elements held ONE page between them — so a passage crossing a page seam
//  was `.notFound` BY CONSTRUCTION. Single-line edits worked and
//  multi-paragraph ones never could.
//
//  AND THE FIX IS NOT MORE ELEMENTS. Enumerating siblings to reassemble pages,
//  normalizing line breaks with an offset map back into some other string,
//  matching short anchors instead of verbatim ones — all of it is machinery
//  for making a SECOND string agree with the first. Do not build it here. An
//  application whose document is not one element joins Mary through a
//  different declaration, not through a cleverer walk.
//
//  THE DECISIONS ARE NOT HERE. Accessibility cannot be exercised in a test
//  process, so which element and which range live in `ProseWriteLocator`,
//  which is pure and table-tested. What follows is a fixed sequence of calls
//  with nothing to choose.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient
import MaryFoundation

public enum ProseSurfaceAX {

    /// Long enough for a large document to come across the boundary, short
    /// enough that a wedged application does not hold a turn. Bonnie measured
    /// its write path against the same order of magnitude.
    static let messagingTimeout: Float = 2.0

    /// The most text this lane will pull across the boundary in one read.
    /// A runaway element cannot drag an unbounded copy into Mary's memory; a
    /// passage past the cap is simply not found, which is the honest answer
    /// rather than a wrong one.
    public static let bodyCap = 500_000

    // MARK: - Finding the surface

    public typealias Surface = DeclaredTextAX.Surface

    /// Every window of `pid` that holds text, in reading order.
    ///
    /// A window with no text element is skipped rather than reported empty:
    /// an inspector panel is not a document, and listing it would put a
    /// choice in front of the user that cannot be written to.
    public static func surfaces(
        pid: pid_t, registration: ProseSurfaceRegistration
    ) -> [Surface] {
        DeclaredTextAX.surfaces(pid: pid, registration: registration)
    }

    /// The surface of the FRONT window, which is what "this document" means.
    public static func frontSurface(
        pid: pid_t, registration: ProseSurfaceRegistration
    ) -> Surface? {
        DeclaredTextAX.frontSurface(pid: pid, registration: registration)
    }

    /// THE TEXT ELEMENT, by the roles the package declared.
    static func editor(
        in window: AXUIElement, registration: ProseSurfaceRegistration
    ) -> AXUIElement? {
        DeclaredTextAX.editor(in: window, registration: registration)
    }

    static func documentKey(
        of window: AXUIElement,
        registration: ProseSurfaceRegistration,
        ordinal: Int
    ) -> String {
        DeclaredTextAX.documentKey(of: window, registration: registration, ordinal: ordinal)
    }

    // MARK: - Reading

    public static func fullString(of element: AXUIElement) -> String? {
        DeclaredTextAX.fullString(of: element)
    }

    // MARK: - Writing

    /// Select `range` — UTF-16, in this element's own coordinates.
    ///
    /// This is half the write, and the half that makes the keystroke fallback
    /// work: once the passage is selected, typing replaces it wherever it is,
    /// so the fallback inherits all of the locating already done.
    @discardableResult
    public static func select(_ range: Range<Int>, in element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let value = withUnsafePointer(to: &cfRange, { AXValueCreate(.cfRange, $0) })
        else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Replace the current selection's text.
    ///
    /// Non-`.success` is the FALLBACK'S CUE, never an error the user hears on
    /// its own: a great many applications implement the range setter and not
    /// this one, and for those the selection above plus keystrokes is a
    /// complete write.
    @discardableResult
    public static func setSelectedText(_ text: String, in element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    /// Bring one window to the front — the fallback for a write that will not
    /// land in the background, and the reason it exists is measured rather
    /// than assumed. See `ProseSurfaceWriter`.
    @discardableResult
    public static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    /// Deep enough for a real editor hierarchy, bounded because the tree
    /// belongs to another process.
    static let descentDepth = 12
    static let descentNodes = 400
}
