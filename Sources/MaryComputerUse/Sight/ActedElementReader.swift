//
//  ActedElementReader.swift
//  MaryComputerUse
//
//  WHAT: Last-acted element from the snapshot roster.
//  IN:   AXElementRoster / PageElementReader  OUT: affordance / spoken resolve

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import MaryAmbient
import MaryFoundation

public enum ActedElementReader {

    /// The focused element of a running process, as a record..
    public static func focusedElement(
        pid: pid_t, capturedAt: Date = Date()
    ) -> AXElementRecord? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        guard let focused = AX.element(application, kAXFocusedUIElementAttribute)
        else { return nil }
        return record(of: focused, pid: pid, capturedAt: capturedAt)
    }

    /// A record for an element the caller already holds — the typer's awaited
    /// text surface, the prose writer's located text area.
    public static func record(
        of element: AXUIElement, pid: pid_t, capturedAt: Date = Date()
    ) -> AXElementRecord? {
        guard let role = AX.string(element, kAXRoleAttribute) else { return nil }
        let label = label(of: element)
        let frame = AX.frame(of: element)

        // THE WINDOW IS CONTEXT, NOT A REQUIREMENT. An element in a sheet or
        // a popover may have no window ancestor this read can reach, and the
        // element is still exactly what was acted on.
        let window = windowElement(of: element)
        let windowFrame = window.flatMap { AX.frame(of: $0) }
        let windowTitle = window.flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        let application = NSRunningApplication(processIdentifier: pid)

        return AXElementRecord(
            identity: ElementIdentity.identity(role: role, label: label),
            // ORDINAL ZERO, MEANING "NOT FROM A ROSTER". A published element's ordinal is
            // its reading-order position among the elements it was published alongside;
            // there is no roster here, and inventing a position would make a record look
            ordinal: 0,
            role: role,
            subrole: AX.string(element, kAXSubroleAttribute),
            label: label,
            kind: PageElementKindDerivation.kind(
                role: role,
                subrole: AX.string(element, kAXSubroleAttribute),
                url: nil,
                label: label,
                frame: frame ?? .zero
            ).spokenWord,
            containerTrail: containerTrail(of: element),
            isEnabled: AX.number(element, kAXEnabledAttribute)?.boolValue ?? true,
            // The act path reads the FOCUSED element, so this is true by
            // construction on the common route — and read rather than assumed,
            // because the other route takes an element the caller located.
            isFocused: AX.number(element, kAXFocusedAttribute)?.boolValue ?? false,
            appName: application?.localizedName ?? "",
            pid: pid,
            windowTitle: windowTitle,
            frame: AXFrameProjection.frame(
                frame ?? .zero,
                inWindow: windowFrame,
                screens: AXFrameProjection.activeScreens(),
                capturedAt: capturedAt))
    }

    // MARK: - Internals

    /// The label a person would use for this element, in the order the
    /// affordance lane reads them — so the identity this produces matches the
    /// identity a walk produces for the same control.
    static func label(of element: AXUIElement) -> String {
        for attribute in [
            kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
        ] {
            if let value = AX.string(element, attribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return ""
    }

    /// The window this element sits in, by walking parents. BOUNDED, because a malformed
    /// hierarchy can cycle: an AX parent chain is another process's data structure, and an
    /// unbounded climb through one is a hang in Mary wearing another application's bug.
    static func windowElement(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<maximumAncestorClimb {
            if AX.string(current, kAXRoleAttribute) == kAXWindowRole as String {
                return current
            }
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// Labeled ancestors, innermost last — "in the sidebar, under Recents".
    static func containerTrail(of element: AXUIElement) -> [String] {
        var trail: [String] = []
        var current = element
        for _ in 0..<maximumAncestorClimb {
            guard let parent = AX.element(current, kAXParentAttribute) else { break }
            if AX.string(parent, kAXRoleAttribute) == kAXWindowRole as String { break }
            if let label = AX.string(parent, kAXTitleAttribute)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                trail.insert(label, at: 0)
            }
            current = parent
        }
        return trail
    }

    /// Deep enough for a real hierarchy, shallow enough that a cyclic one
    /// costs milliseconds rather than a turn.
    static let maximumAncestorClimb = 24
}
