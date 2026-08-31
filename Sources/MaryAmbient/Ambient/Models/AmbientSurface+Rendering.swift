//
//  AmbientSurface+Rendering.swift
//  MaryBrain
//
//  WHAT: One phrasing for a surface — prompt and pane both call surfaceLine(at:).
//  IN:   AmbientSurface
//  OUT:  TIER 0 prompt line. Specific elements ride AmbientElementIndex.
//  PIN:  Never the roster. Line names at most notableLimit; rest is a count.
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
