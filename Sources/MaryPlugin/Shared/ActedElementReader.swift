//
//  ActedElementReader.swift
//  MaryPlugin
//
//  WHAT WAS JUST ACTED ON, READ AT THE MOMENT OF ACTING.
//
//  An adapter that types, presses or writes knows the act happened; what it
//  has never known is WHERE. Bonnie's typer awaited a focused text surface and
//  returned a `Bool`, discarding the element it had just proven; its hands
//  returned a window rectangle and an opaque token. So no record of any action
//  could say what it touched, and "she typed into the wrong window" was a
//  report nobody could check afterwards.
//
//  This reader closes that. One AX read of the focused element, turned into
//  the same `AXElementRecord` the surface tier publishes, so an action's
//  target and a captured surface element line up by identity — the join the
//  behavioural dataset is built on.
//
//  WHY NOT `AmbientBridge.record(from:window:capturedAt:)`. That takes an
//  `AXScreenElement` from a completed tree WALK, and this path has no walk: an
//  adapter about to type holds a focused element and nothing else, and walking
//  the whole application to describe one element would be a second, slower,
//  possibly-disagreeing answer to a question already settled. Both funnel
//  through the SAME identity and kind spellings (`AmbientBridge.identity`,
//  `PageElementKindDerivation`), which is what makes the two records
//  comparable — pinned by test rather than by intention.
//
//  BEST EFFORT, ALWAYS. Every failure returns nil: no accessibility grant, a
//  process that just exited, an application that exposes no focused element.
//  An act that worked must never be reported as failed because describing it
//  did not, so no caller may treat nil as anything but "unrecorded".
//

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import MaryAmbient
import MaryFoundation

public enum ActedElementReader {

    /// The focused element of a running process, as a record.
    ///
    /// - Parameters:
    ///   - pid: the process that was acted on.
    ///   - capturedAt: the moment to stamp. Passed rather than taken so a
    ///     caller can stamp the act's own instant instead of the instant it
    ///     got round to describing it.
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
            identity: AmbientBridge.identity(role: role, label: label),
            // ORDINAL ZERO, MEANING "NOT FROM A ROSTER". A published element's
            // ordinal is its reading-order position among the elements it was
            // published alongside; there is no roster here, and inventing a
            // position would make a record look like it came from a walk.
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

    /// The window this element sits in, by walking parents.
    ///
    /// BOUNDED, because a malformed hierarchy can cycle: an AX parent chain is
    /// another process's data structure, and an unbounded climb through one is
    /// a hang in Mary wearing another application's bug.
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
