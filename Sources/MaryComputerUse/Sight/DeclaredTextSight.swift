//
//  DeclaredTextSight.swift
//  MaryComputerUse
//
//  WHAT: Turn-local sight from the tagged declared-editor pane.
//  IN:   DeclaredTextAX (same node whose bbox justified look)
//  OUT:  FocusPaneTarget / fetch-first
//

import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient
import os

/// Document identity + selection offsets from the tagged editor element.
public struct DeclaredTextSight: Sendable, Equatable {
    public var place: AmbientPlace
    public var identity: String
    public var frame: CGRect
    public var documentKey: String?
    public var documentTitle: String?
    public var selectedRange: Range<Int>?

    public init(
        place: AmbientPlace,
        identity: String,
        frame: CGRect,
        documentKey: String? = nil,
        documentTitle: String? = nil,
        selectedRange: Range<Int>? = nil
    ) {
        self.place = place
        self.identity = identity
        self.frame = frame
        self.documentKey = documentKey
        self.documentTitle = documentTitle
        self.selectedRange = selectedRange
    }

    public var hasHighlight: Bool {
        guard let selectedRange else { return false }
        return !selectedRange.isEmpty
    }
}

/// Process-wide standing sight for the tagged pane.
public final class DeclaredTextSightStore: @unchecked Sendable {
    public static let shared = DeclaredTextSightStore()

    private let box = OSAllocatedUnfairLock<DeclaredTextSight?>(initialState: nil)

    public init() {}

    public func note(_ sight: DeclaredTextSight?) {
        box.withLock { $0 = sight }
    }

    public func current() -> DeclaredTextSight? {
        box.withLock { $0 }
    }

    public func clear(place: AmbientPlace? = nil) {
        box.withLock { held in
            if let place, held?.place != place { return }
            held = nil
        }
    }
}

public enum DeclaredTextSightPublisher {

    /// Stamp pane bbox + document/selection from the same AX editor node.
    public static func publish(
        place: AmbientPlace,
        editor: AXUIElement,
        window: AXUIElement,
        registration: some DeclaredTextSurface,
        tracker: WorkspaceFocusTracker = .shared,
        store: DeclaredTextSightStore = .shared
    ) {
        let role = AX.string(editor, kAXRoleAttribute) ?? "AXTextArea"
        let windowTitle = AX.string(window, kAXTitleAttribute) ?? ""
        let label = AXElementRoster.fallbackEditorLabel(
            role: role,
            windowTitle: windowTitle,
            containerTrail: [],
            isFocused: DeclaredTextAX.isFocused(editor))
        let identity = ElementIdentity.identity(role: role, label: label)
        let frame = AX.frame(of: editor) ?? .zero
        if frame.width > 0, frame.height > 0 {
            tracker.notePaneTarget(FocusPaneTarget(
                place: place, identity: identity, frame: frame))
        }
        store.note(DeclaredTextSight(
            place: place,
            identity: identity,
            frame: frame,
            documentKey: DeclaredTextAX.documentKey(
                of: window, registration: registration, ordinal: 1),
            documentTitle: DeclaredTextAX.documentSubject(of: window),
            selectedRange: DeclaredTextAX.selectedRange(of: editor)))
    }
}
