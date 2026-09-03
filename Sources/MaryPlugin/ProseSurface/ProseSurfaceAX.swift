//
//  ProseSurfaceAX.swift
//  MaryPlugin
//
//  WHAT: Read/write one AX text element. No application named.
//  IN:   ProseSurfaceRegistration  OUT: ProseSurfaceWriter
//  PIN:  One-element documents only. Page-partitioned apps use another declaration.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

public enum ProseSurfaceAX {

    /// Long enough for a large document to come across the boundary, short enough that a
    /// wedged application does not hold a turn.
    static let messagingTimeout: Float = 2.0

    /// The most text this lane will pull across the boundary in one read.
    public static let bodyCap = 500_000

    // MARK: - Finding the surface

    public typealias Surface = DeclaredTextAX.Surface

    /// Every window of `pid` that holds text, in reading order.
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
    @discardableResult
    public static func select(_ range: Range<Int>, in element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let value = withUnsafePointer(to: &cfRange, { AXValueCreate(.cfRange, $0) })
        else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Replace the current selection's text. Non-`.success` is the FALLBACK'S CUE, never an
    /// error the user hears on its own: a great many applications implement the range
    /// setter and not this one, and for those the selection above plus keystrokes is a
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
