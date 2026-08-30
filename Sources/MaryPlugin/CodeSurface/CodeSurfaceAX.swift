//
//  CodeSurfaceAX.swift
//  MaryPlugin
//
//  READING AN APPLICATION'S LIVE CODE BUFFER THROUGH ACCESSIBILITY — with no
//  application named anywhere in this file.
//
//  Locate and buffer reads live on `DeclaredTextAX` (shared with prose).
//  This file is the code-surface name for those reads. READ-ONLY,
//  DELIBERATELY — no `select`/`setSelectedText` here. Write policy stays on
//  `CodeSurfaceWriter` (disk + dirty-buffer gate).
//

import ApplicationServices
import CoreGraphics
import Foundation
import MaryFoundation

public enum CodeSurfaceAX {

    static let messagingTimeout = DeclaredTextAX.messagingTimeout
    public static let bodyCap = DeclaredTextAX.bodyCap

    public typealias Surface = DeclaredTextAX.Surface
    public typealias EditorCandidate = DeclaredTextAX.EditorCandidate

    public static func surfaces(
        pid: pid_t, registration: CodeSurfaceRegistration
    ) -> [Surface] {
        DeclaredTextAX.surfaces(pid: pid, registration: registration)
    }

    public static func frontSurface(
        pid: pid_t, registration: CodeSurfaceRegistration
    ) -> Surface? {
        DeclaredTextAX.frontSurface(pid: pid, registration: registration)
    }

    public static func editor(
        in window: AXUIElement, registration: CodeSurfaceRegistration
    ) -> AXUIElement? {
        DeclaredTextAX.editor(in: window, registration: registration)
    }

    public static func pickEditor(
        from candidates: [EditorCandidate],
        preferredRoles: [String],
        preferFocused: Bool
    ) -> Int? {
        DeclaredTextAX.pickEditor(
            from: candidates, preferredRoles: preferredRoles, preferFocused: preferFocused)
    }

    public static func isFocused(_ element: AXUIElement) -> Bool {
        DeclaredTextAX.isFocused(element)
    }

    static func documentKey(
        of window: AXUIElement,
        registration: CodeSurfaceRegistration,
        ordinal: Int
    ) -> String {
        DeclaredTextAX.documentKey(of: window, registration: registration, ordinal: ordinal)
    }

    public static func fullString(of element: AXUIElement) -> String? {
        DeclaredTextAX.fullString(of: element)
    }

    public static func characterCount(of element: AXUIElement) -> Int? {
        DeclaredTextAX.characterCount(of: element)
    }

    public static func substring(of element: AXUIElement, range: Range<Int>) -> String? {
        DeclaredTextAX.substring(of: element, range: range)
    }

    public static func selectedRange(of element: AXUIElement) -> Range<Int>? {
        DeclaredTextAX.selectedRange(of: element)
    }
}
