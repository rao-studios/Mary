//
//  AmbientSurfaceBridge.swift
//  MaryAdapter
//
//  WHAT: AXScreenElement → AXElementRecord (geometry here via AXFrameProjection).
//  IN:   AXEngine snapshot  OUT: ambient store
//  PIN:  Identity/kind attach here; AXEngine must not import Shared/.

import CoreGraphics
import Foundation

public extension AmbientBridge {

    /// The tier-0 record: the engine's artifact in ambient vocabulary, with the family lane
    /// attached HERE — the engine stays app-agnostic; place resolution is the bridge's job,
    /// exactly.
    static func surface(
        from context: AXAmbientContext, place: AmbientPlace
    ) -> AmbientSurface {
        let window = context.activeWindow?.frame
        let screens = AXFrameProjection.activeScreens()
        let capturedAt = context.capture.capturedAt
        return AmbientSurface(
            place: place,
            application: .init(
                name: context.app.appName,
                bundleID: context.app.bundleID,
                pid: context.app.pid),
            activeWindow: context.activeWindow.map {
                AmbientSurface.Window(
                    title: $0.title,
                    frame: $0.frame.map {
                        AXFrameProjection.frame(
                            $0, screens: screens, capturedAt: capturedAt)
                    })
            },
            windowCount: context.windowCount,
            minimizedCount: context.minimizedCount,
            elements: context.elements.map {
                surfaceElement(from: $0, window: window, screens: screens, capturedAt: capturedAt)
            },
            focused: context.focused.map { focused in
                // The single most act-relevant element on screen — it now
                // carries a frame when the walk answered one, rather than
                // being built with none.
                AmbientSurface.Element(
                    identity: identity(
                        role: focused.role, label: focused.label ?? ""),
                    ordinal: 0,
                    role: focused.role,
                    kind: kindWord(
                        role: focused.role, subrole: nil,
                        label: focused.label ?? "", frame: focused.frame ?? .zero),
                    label: focused.label ?? "",
                    frame: focused.frame.map {
                        AXFrameProjection.frame(
                            $0, inWindow: window, screens: screens, capturedAt: capturedAt)
                    })
            },
            pageNotYetRead: pageNotYetRead(context),
            capturedAt: capturedAt)
    }

    /// One element, addressed AND located — what Clyde's inspector shows and
    /// `--probe-ambient-surface` prints.
    static func record(
        from element: AXScreenElement, window: CGRect?, capturedAt: Date
    ) -> AXElementRecord {
        AXElementRecord(
            identity: identity(of: element),
            ordinal: element.ordinal,
            role: element.role,
            subrole: element.subrole,
            label: element.label,
            kind: kindWord(
                role: element.role, subrole: element.subrole,
                label: element.label, frame: element.frame),
            containerTrail: element.containerTrail,
            isEnabled: element.isEnabled,
            isFocused: element.isFocused,
            appName: element.appName,
            pid: Int32(element.pid),
            windowTitle: element.windowTitle,
            frame: AXFrameProjection.frame(
                element.frame, inWindow: window,
                screens: AXFrameProjection.activeScreens(), capturedAt: capturedAt))
    }

    /// The affordance slate from the same walk: the roster filtered to the page lane's
    /// collected roles, floored at its 8pt human size for the non-interactive categories
    /// the roster admits at the 2pt hit-test floor (rows, cells, images, headings.
    static func affordances(
        from context: AXAmbientContext
    ) -> [AmbientAffordance] {
        let collected = context.elements.filter { element in
            guard PageElementReader.collectedRoles.contains(element.role)
            else { return false }
            if element.category == .interactive || element.category == .scripted {
                return true
            }
            return min(element.frame.width, element.frame.height)
                >= AXElementRoster.minimumInteractiveSide
        }
        let window = context.activeWindow?.frame
        let screens = AXFrameProjection.activeScreens()
        let capturedAt = context.capture.capturedAt
        return collected.enumerated().map { index, element in
            AmbientAffordance(
                id: identity(of: element),
                label: element.label,
                roleWord: kindWord(
                    role: element.role, subrole: element.subrole,
                    label: element.label, frame: element.frame),
                ordinal: index + 1,
                isEnabled: element.isEnabled,
                help: nil,
                frame: AXFrameProjection.frame(
                    element.frame, inWindow: window, screens: screens,
                    capturedAt: capturedAt))
        }
    }

    /// `AffordanceResolver.identity(of:)`, spelled for a snapshot element —
    /// byte-for-byte the same format, pinned by test.
    static func identity(of element: AXScreenElement) -> String {
        identity(role: element.role, label: element.label)
    }

    /// The re-finding key from the two parts that make it. Both callers go
    /// through this, so a focused element and a rostered one can never be
    /// spelled differently.
    static func identity(role: String, label: String) -> String {
        "\(role.lowercased())|\(PageElementResolver.normalized(label))"
    }

    // MARK: - Internals

    /// The page lane's own humanized word. A snapshot has no URL — exactly
    /// as `AXScreenElement`'s header records — so the playable-URL rung of
    /// the derivation never fires here.
    private static func kindWord(
        role: String, subrole: String?, label: String, frame: CGRect
    ) -> String {
        PageElementKindDerivation.kind(
            role: role, subrole: subrole, url: nil, label: label, frame: frame
        ).spokenWord
    }

    private static func surfaceElement(
        from element: AXScreenElement, window: CGRect?, screens: [CGRect], capturedAt: Date
    ) -> AmbientSurface.Element {
        AmbientSurface.Element(
            // Identity shared with the affordance so a captured element and a live re-read join.
            identity: identity(of: element),
            ordinal: element.ordinal,
            role: element.role,
            kind: kindWord(
                role: element.role, subrole: element.subrole,
                label: element.label, frame: element.frame),
            label: element.label,
            frame: AXFrameProjection.frame(
                element.frame, inWindow: window, screens: screens, capturedAt: capturedAt),
            isFocused: element.isFocused,
            isEnabled: element.isEnabled,
            containerTrail: element.containerTrail)
    }

    /// The honest "I cannot see the page YET": the host classifier says web
    /// content exists, and the walk found no web area.
    private static func pageNotYetRead(_ context: AXAmbientContext) -> Bool {
        context.webContentHost
    }
}
