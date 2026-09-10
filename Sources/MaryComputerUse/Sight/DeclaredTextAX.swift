//
//  DeclaredTextAX.swift
//  MaryComputerUse
//
//  WHAT: Locate the declared text element in a focused window.
//  IN:   SurfacePollTarget pid  OUT: CodeSurfaceAX | ProseSurfaceAX
//  PIN:  Locate only. Write policy stays on the family writers.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryFoundation

/// Coordinates a package declared for a live text buffer.
public protocol DeclaredTextSurface: Sendable {
    var applicationID: String { get }
    var editorRoleNames: [String] { get }
    var documentKeyKind: PluginProseDocumentKey { get }
    var preferFocusedElement: Bool { get }
    var editorWalkBudget: AXTreeWalker.Budget { get }
}

public enum DeclaredTextAX {

    public static let messagingTimeout: Float = 2.0
    public static let bodyCap = 500_000

    public struct Surface: Sendable {
        public let window: AXUIElement
        public let editor: AXUIElement
        public let documentKey: String
        public let title: String
        public let ordinal: Int

        public init(
            window: AXUIElement, editor: AXUIElement,
            documentKey: String, title: String, ordinal: Int
        ) {
            self.window = window
            self.editor = editor
            self.documentKey = documentKey
            self.title = title
            self.ordinal = ordinal
        }
    }

    public struct EditorCandidate: Sendable, Equatable {
        public var role: String
        public var area: CGFloat
        public var focused: Bool

        public init(role: String, area: CGFloat, focused: Bool) {
            self.role = role
            self.area = area
            self.focused = focused
        }
    }

    public static func surfaces(
        pid: pid_t, registration: some DeclaredTextSurface
    ) -> [Surface] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let windows = AX.children(application, kAXWindowsAttribute)

        var found: [Surface] = []
        for window in windows {
            guard let editor = editor(in: window, registration: registration) else { continue }
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            found.append(Surface(
                window: window,
                editor: editor,
                documentKey: documentKey(
                    of: window, registration: registration, ordinal: found.count + 1),
                title: title,
                ordinal: found.count + 1))
        }
        return found
    }

    public static func frontSurface(
        pid: pid_t, registration: some DeclaredTextSurface
    ) -> Surface? {
        surfaces(pid: pid, registration: registration).first
    }

    public static func editor(
        in window: AXUIElement, registration: some DeclaredTextSurface
    ) -> AXUIElement? {
        var found: [(element: AXUIElement, candidate: EditorCandidate)] = []
        AXTreeWalker.walk(
            from: window,
            budget: registration.editorWalkBudget
        ) { element, _ in
            guard let role = AX.string(element, kAXRoleAttribute) else { return }
            guard registration.editorRoleNames.contains(role) else { return }
            let frame = AX.frame(of: element)
            let area = (frame?.width ?? 0) * (frame?.height ?? 0)
            found.append((
                element,
                EditorCandidate(role: role, area: area, focused: isFocused(element))))
        }
        guard let index = pickEditor(
            from: found.map(\.candidate),
            preferredRoles: registration.editorRoleNames,
            preferFocused: registration.preferFocusedElement)
        else { return nil }
        return found[index].element
    }

    public static func pickEditor(
        from candidates: [EditorCandidate],
        preferredRoles: [String],
        preferFocused: Bool
    ) -> Int? {
        if preferFocused {
            for role in preferredRoles {
                if let index = candidates.firstIndex(where: { $0.role == role && $0.focused }) {
                    return index
                }
            }
        }
        for role in preferredRoles {
            let matching = candidates.enumerated().filter { $0.element.role == role }
            if let best = matching.max(by: { $0.element.area < $1.element.area }) {
                return best.offset
            }
        }
        return nil
    }

    public static func isFocused(_ element: AXUIElement) -> Bool {
        if let flag = AX.attribute(element, kAXFocusedAttribute) as? Bool { return flag }
        return AX.number(element, kAXFocusedAttribute)?.boolValue ?? false
    }

    public static func documentKey(
        of window: AXUIElement,
        registration: some DeclaredTextSurface,
        ordinal: Int
    ) -> String {
        if registration.documentKeyKind == .documentPathThenWindow,
           let path = AX.string(window, kAXDocumentAttribute), !path.isEmpty {
            return path
        }
        return "\(registration.applicationID):win\(ordinal)"
    }

    public static func fullString(of element: AXUIElement) -> String? {
        if let total = characterCount(of: element), total > 0,
           let text = substring(of: element, range: 0..<min(total, bodyCap)) {
            return text
        }
        return AX.string(element, kAXValueAttribute).map { String($0.prefix(bodyCap)) }
    }

    public static func characterCount(of element: AXUIElement) -> Int? {
        AX.number(element, kAXNumberOfCharactersAttribute)?.intValue
    }

    public static func substring(of element: AXUIElement, range: Range<Int>) -> String? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let parameter = withUnsafePointer(to: &cfRange, { AXValueCreate(.cfRange, $0) })
        else { return nil }
        return AX.parameterized(
            element, kAXStringForRangeParameterizedAttribute, parameter: parameter) as? String
    }

    public static func selectedRange(of element: AXUIElement) -> Range<Int>? {
        AX.range(element, kAXSelectedTextRangeAttribute)
    }

    /// The file this window is showing, by name. `AXDocument` is a `file://` URL string —
    /// measured, and the reason `CodeSurfaceWriter.fileURL` exists — and against Xcode.
    ///
    /// PIN: lives here, beside the other declared-text reads, because prose,
    /// code and the sight lane all ask this same question of a window.
    public static func documentSubject(of window: AXUIElement) -> String? {
        if let raw = AX.string(window, kAXDocumentAttribute), !raw.isEmpty {
            let path = URL(string: raw)?.path ?? raw
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let title = AX.string(window, kAXTitleAttribute)
        return title?.isEmpty == false ? title : nil
    }
}
