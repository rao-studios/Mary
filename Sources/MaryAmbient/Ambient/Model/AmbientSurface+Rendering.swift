//
//  AmbientSurface+Rendering.swift
//  MaryBrain
//
//  ONE PHRASING, TWO READERS — the `AmbientFact+Rendering` doctrine: the
//  prompt and the pane both call `surfaceLine(at:)`, so they cannot phrase
//  the same screen two ways.
//
//  NEVER THE ROSTER. A surface holds up to 120 elements; the LINE names at
//  most `notableLimit` of them (focused first, then reading order) and says
//  how many more there are. The prompt gets orientation, not an inventory —
//  a phrase that needs a specific element rides the element index, which
//  holds the full slate.
//

import Foundation

public extension AmbientSurface {

    /// Hard cap on the rendered line.
    static let surfaceLineCap = 220
    /// Element labels the line may name.
    static let notableLimit = 5

    /// "On screen: Pages — "Kohinoor Essay" (front of 2 windows; focused:
    /// body text) — offering: Share, Add Page, Zoom, +38 more — seen 8s ago"
    func surfaceLine(at now: Date = Date()) -> String {
        var line = "On screen: \(application.name)"
        if let window = activeWindow, !window.title.isEmpty {
            line += " — \"\(window.title)\""
        }

        var qualifiers: [String] = []
        if windowCount > 1 {
            var windows = "front of \(windowCount) windows"
            if minimizedCount > 0 { windows += ", \(minimizedCount) minimized" }
            qualifiers.append(windows)
        }
        if let focused {
            qualifiers.append("focused: \(focused.descriptor)")
        }
        if !qualifiers.isEmpty {
            line += " (\(qualifiers.joined(separator: "; ")))"
        }

        if !elements.isEmpty {
            var named: [String] = []
            var seen = Set<Int>()
            if let focused, !focused.label.isEmpty {
                named.append(focused.label)
                seen.insert(focused.ordinal)
            }
            for element in elements where named.count < Self.notableLimit {
                guard !seen.contains(element.ordinal), !element.label.isEmpty
                else { continue }
                named.append(element.label)
                seen.insert(element.ordinal)
            }
            if !named.isEmpty {
                var offering = " — offering: \(named.joined(separator: ", "))"
                let remainder = elements.count - named.count
                if remainder > 0 { offering += ", +\(remainder) more" }
                line += offering
            }
        }

        if pageNotYetRead {
            line += " — page not yet read"
        }

        line += " — seen \(AmbientAge.string(age(at: now))) ago"

        guard line.count > Self.surfaceLineCap else { return line }
        return line.prefix(Self.surfaceLineCap - 1) + "…"
    }
}
