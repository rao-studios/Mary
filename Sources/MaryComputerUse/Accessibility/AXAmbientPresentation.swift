//
//  AXAmbientPresentation.swift
//  MaryComputerUse
//
//  WHAT: AXAmbientContext as HUD/inspector rows. Pure formatting, no SwiftUI.
//  OUT:  WireframeHUD | inspector
//  PIN:  "—" is missing; never a blank or a zero pretending to be an answer.

import CoreGraphics
import Foundation

public enum AXAmbientPresentation {

    /// One label/value row, in the shape `WireframeHUD.row` lays out.
    /// `id` is the label: row labels here are fixed vocabulary ("Elements",
    /// "Web"), one per group, never data-derived.
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// One roster line for the inspector panel. `id` is the element's own
    /// node id — labels repeat (two "Save" buttons), node ids do not within
    /// one published list.
    public struct ElementLine: Sendable, Equatable, Identifiable {
        public var id: UInt
        public var ordinal: Int
        public var text: String
        public var trail: String?
        public var isFocused: Bool
        public var isEnabled: Bool

        public init(
            id: UInt, ordinal: Int, text: String, trail: String?,
            isFocused: Bool, isEnabled: Bool
        ) {
            self.id = id
            self.ordinal = ordinal
            self.text = text
            self.trail = trail
            self.isFocused = isFocused
            self.isEnabled = isEnabled
        }
    }

    /// Longest window title a compact HUD row carries before eliding.
    public static let summaryTitleCap = 40

    // MARK: - The HUD's compact group

    /// The "Ambient" group for the HUD proper: always the window and the
    /// element count; the focused and web rows only when they have something
    /// to say (the self-suppression idiom).
    public static func summaryRows(for context: AXAmbientContext) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(
            label: "Active window",
            value: context.activeWindow.map { elided($0.title) } ?? "—"))
        rows.append(Row(
            label: "Elements",
            value: "\(context.elements.count) \(context.scope.rawValue)"))
        if let focused = context.focused {
            rows.append(Row(label: "Focused", value: descriptor(for: focused)))
        }
        if context.webContentHost {
            rows.append(Row(label: "Web", value: "web content — page not read"))
        }
        return rows
    }

    // MARK: - The inspector panel's header

    public static func headerRows(for context: AXAmbientContext) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(
            label: "App",
            value: "\(context.app.appName) (pid \(context.app.pid))"))
        rows.append(Row(label: "Window", value: windowValue(for: context)))
        rows.append(Row(label: "Capture", value: captureValue(context.capture)))
        if let covered = context.capture.observersCovered,
           let total = context.capture.observersTotal {
            rows.append(Row(label: "Observers", value: "\(covered)/\(total)"))
        }
        if context.webContentHost {
            rows.append(Row(label: "Web", value: "web content — page not read"))
        }
        return rows
    }

    // MARK: - The roster

    public static func elementLines(for context: AXAmbientContext) -> [ElementLine] {
        context.elements.map { element in
            ElementLine(
                id: element.id.raw,
                ordinal: element.ordinal,
                text: "\(element.ordinal) · \(word(for: element.category)) · \(element.label)",
                trail: element.containerTrail.isEmpty
                    ? nil : element.containerTrail.joined(separator: " › "),
                isFocused: element.isFocused,
                isEnabled: element.isEnabled)
        }
    }

    /// "text field 'Search' (AXTextField)" — or without a label, just the
    /// humanized word and the raw role. Nil when nothing claims focus.
    public static func focusedLine(for context: AXAmbientContext) -> String? {
        context.focused.map(descriptor(for:))
    }

    // MARK: - Words

    /// `AXTextField` → "text field", `MaryScripted` → "scripted" — the raw role humanized
    /// mechanically, no per-app table.
    public static func roleWord(_ role: String) -> String {
        if role == "MaryScripted" { return "scripted" }
        var stripped = role
        if stripped.hasPrefix("AX") { stripped = String(stripped.dropFirst(2)) }
        guard !stripped.isEmpty else { return role.lowercased() }
        var words: [String] = []
        var current = ""
        for character in stripped {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }

    /// The category's one-word answer for a roster line.
    public static func word(for category: AXNodeCategory) -> String {
        switch category {
        case .interactive: return "control"
        case .text: return "text"
        case .image: return "image"
        case .container: return "group"
        case .scrollArea: return "scroll"
        case .webArea: return "page"
        case .scripted: return "scripted"
        case .window: return "window"
        case .other: return "other"
        }
    }

    // MARK: - Values

    static func descriptor(for focused: AXAmbientContext.FocusedElement) -> String {
        let word = roleWord(focused.role)
        if let label = focused.label, !label.isEmpty {
            return "\(word) '\(elided(label))' (\(focused.role))"
        }
        return "\(word) (\(focused.role))"
    }

    static func windowValue(for context: AXAmbientContext) -> String {
        guard let window = context.activeWindow else { return "—" }
        var value = "\"\(elided(window.title))\""
        if context.windowCount > 1 {
            value += " — front of \(context.windowCount)"
            if context.minimizedCount > 0 {
                value += ", \(context.minimizedCount) minimized"
            }
        }
        if window.isTruncated { value += " · truncated" }
        return value
    }

    static func captureValue(_ capture: AXAmbientContext.Capture) -> String {
        var value = "\(capture.nodeCount) nodes · \(milliseconds(capture.walkDuration))"
        if capture.isTruncated { value += " · truncated" }
        return value
    }

    static func elided(_ text: String) -> String {
        guard text.count > summaryTitleCap else { return text }
        return text.prefix(summaryTitleCap - 1) + "…"
    }

    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) * 1e-15
        return String(format: "%.1f ms", ms)
    }
}
