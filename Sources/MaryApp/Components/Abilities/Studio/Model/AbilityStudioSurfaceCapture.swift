//
//  AbilityStudioSurfaceCapture.swift
//  Mary
//
//  WHAT: A live accessibility read of the application an expertise teaches.
//  IN:   Draft-a-skill sheet.
//  OUT:  AXEngine.snapshot → AXElementRoster.elements, trimmed for a prompt.
//  PIN:  Bounded on purpose. A drafter given four hundred frames writes worse
//        blocks than one given the sixty the author actually pointed at.
//

import MaryBrain
import MaryPlugin
import Foundation
import MaryComputerUse

/// One accessibility frame, as the drafter is allowed to see it.
struct AbilityStudioSurfaceFrame: Identifiable, Hashable {
    let id: String
    let role: String
    let label: String
    let trail: [String]
    let isEnabled: Bool
    let isFocused: Bool

    /// "AXOutline “Playlists” · AXWindow ▸ AXSplitGroup" — one line the model
    /// can name an anchor from.
    var line: String {
        var parts = ["\(role) \u{201C}\(label)\u{201D}"]
        if !trail.isEmpty { parts.append(trail.joined(separator: " > ")) }
        if !isEnabled { parts.append("disabled") }
        if isFocused { parts.append("focused") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct AbilityStudioSurfaceCapture {

    enum Outcome {
        case captured([AbilityStudioSurfaceFrame])
        /// The app is not running, or accessibility is not granted.
        case unavailable(reason: String)

        var frames: [AbilityStudioSurfaceFrame] {
            if case .captured(let frames) = self { return frames }
            return []
        }

        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// How many frames one capture offers the author to choose from.
    static let limit = 60

    /// Reads the front window of the application this package teaches.
    static func read(
        package: MaryAbilityPackage,
        locator: PluginApplicationLocator = .live
    ) -> Outcome {
        guard let application = package.plugin?.application else {
            return .unavailable(reason: "This ability teaches no application.")
        }
        let resolution = locator.resolve(application)
        switch resolution.status {
        case .notFound:
            return .unavailable(
                reason: "\(application.title) is not installed on this Mac.")
        case .installed:
            return .unavailable(
                reason: "Open \(application.title) first — Mary reads the window that is actually there.")
        case .ambiguous:
            return .unavailable(
                reason: "More than one process answers to \(application.title); Mary will not guess which.")
        case .running:
            break
        }
        guard let pid = resolution.processIdentifier else {
            return .unavailable(reason: "\(application.title) is running but did not report a process.")
        }
        guard let snapshot = AXEngine.snapshot(pid: pid) else {
            return .unavailable(
                reason: "Mary could not read \(application.title). Check Accessibility permission in System Settings.")
        }
        let elements = AXElementRoster.elements(
            in: snapshot,
            scope: .actionable,
            windows: .front,
            limit: limit)
        guard !elements.isEmpty else {
            return .unavailable(
                reason: "\(application.title) has no readable window in front right now.")
        }
        return .captured(elements.map(frame))
    }

    private static func frame(_ element: AXScreenElement) -> AbilityStudioSurfaceFrame {
        AbilityStudioSurfaceFrame(
            id: "\(element.ordinal)/\(element.role)/\(element.label)",
            role: element.role,
            label: element.label,
            trail: element.containerTrail,
            isEnabled: element.isEnabled,
            isFocused: element.isFocused)
    }
}
