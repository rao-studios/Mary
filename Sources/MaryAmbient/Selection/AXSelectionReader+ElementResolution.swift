//
//  AXSelectionReader+ElementResolution.swift
//  MaryAmbient
//
//  WHAT: Element-resolution cascade for a focused or changed AX node.
//  IN:   AXSelectionReader.swift (split)
//  OUT:  AXSelectionReader+Reads
//

import AppKit
import ApplicationServices
import MaryFoundation
import Foundation

extension AXSelectionReader {

    // MARK: - Element resolution
    // Same cascade as `PagesAX.textElement(of:)` / `descendToText(from:)` — equivalent shape, not shared code.

    static func textElement(
        of app: AXUIElement
    ) -> (element: AXUIElement, resolution: PerceptionElementResolution)? {
        if let focused = copyElement(app, kAXFocusedUIElementAttribute), isTextual(focused) {
            return (focused, .focusedElement)
        }
        guard let window = copyElement(app, kAXMainWindowAttribute) else { return nil }
        return descendToText(from: window)
    }

    /// Breadth-first, hard-bounded by depth AND node count. Prefers a real `AXTextArea`;
    /// accepts any element that answers a text attribute as a fallback, since an arbitrary
    /// third-party app's text-carrying role is unknowable in advance.
    private static func descendToText(
        from root: AXUIElement
    ) -> (element: AXUIElement, resolution: PerceptionElementResolution)? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0
        var capable: AXUIElement?
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if visited > maxSearchNodes { break }

            let role = copyString(element, kAXRoleAttribute)
            if role == kAXTextAreaRole as String, isTextual(element) {
                return (element, .mainWindowDescent)
            }
            if capable == nil, isTextual(element) { capable = element }

            guard depth < maxSearchDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return capable.map { ($0, .capabilityFallback) }
    }

    /// An evidence-bearing descendant. A readable `.selected` is what the
    /// source ability can publish; an unreadable nonempty range is still a
    /// competing selection and therefore blocks choosing some other leaf.
    struct SelectionCandidate {
        let state: SelectionState
        let element: AXUIElement

        var surfaceID: UInt { AXSelectionReader.sourceSurfaceID(of: element) }
    }

    /// The pure decision behind a bounded discovery walk. It is deliberately not "first
    /// positive wins": AX tree order is layout order, not the user interaction.
    enum SelectionDiscoveryOutcome {
        case selected(SelectionCandidate)
        case unreadable(SelectionCandidate)
        case ambiguous
        case none
    }

    struct SelectionDiscovery {
        private var candidate: SelectionCandidate?
        private var candidates: [DiscoveredSelectionCandidate] = []
        private(set) var isAmbiguous = false
        private var seenSurfaces: Set<UInt> = []

        mutating func consider(_ state: SelectionState, from element: AXUIElement) {
            guard !isAmbiguous else { return }
            switch state {
            case .selected, .unreadableNonemptyRange:
                let incoming = SelectionCandidate(state: state, element: element)
                // A main-window descent can revisit a focused-subtree leaf. Rechecking the same AX object
                // does not make the source ambiguous; a second AX object always does.
                guard seenSurfaces.insert(incoming.surfaceID).inserted else { return }
                switch state {
                case .selected:
                    candidates.append(.selected(surfaceID: incoming.surfaceID))
                case .unreadableNonemptyRange:
                    candidates.append(.unreadableNonemptyRange(surfaceID: incoming.surfaceID))
                case .caret, .ambiguousSelection, .unavailable:
                    break
                }
                guard candidate != nil else {
                    self.candidate = incoming
                    return
                }
                isAmbiguous = AXSelectionReader.discoveredSelectionDisposition(
                    for: candidates) == .ambiguous
            case .caret, .ambiguousSelection, .unavailable:
                break
            }
        }

        var outcome: SelectionDiscoveryOutcome {
            switch AXSelectionReader.discoveredSelectionDisposition(for: candidates) {
            case .ambiguous:
                return .ambiguous
            case .none:
                return .none
            case .selected, .unreadableNonemptyRange:
                break
            }
            guard let candidate else { return .none }
            switch candidate.state {
            case .selected:
                return .selected(candidate)
            case .unreadableNonemptyRange:
                return .unreadable(candidate)
            case .caret, .ambiguousSelection, .unavailable:
                return .none
            }
        }
    }

    /// Search a bounded AX subtree for explicit selection evidence. Unlike `descendToText`,
    /// this intentionally remembers no merely textual nodes.
    static func collectSelectionEvidence(
        of root: AXUIElement,
        includeRoot: Bool,
        messagingTimeout: TimeInterval,
        deadline: Date,
        resolution: PerceptionElementResolution,
        into discovery: inout SelectionDiscovery
    ) {
        var queue: [(element: AXUIElement, depth: Int)] = includeRoot
            ? [(root, 0)]
            : children(of: root).map { ($0, 1) }
        var visited = 0

        while !queue.isEmpty, !discovery.isAmbiguous {
            guard Date() <= deadline else { return }
            let (element, depth) = queue.removeFirst()
            visited += 1
            if visited > maxSearchNodes { break }
            AXUIElementSetMessagingTimeout(element, Float(messagingTimeout))
            discovery.consider(
                selectionState(of: element, resolution: resolution), from: element)
            guard Date() <= deadline, !discovery.isAmbiguous else { return }

            guard depth < maxSearchDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        Array(AX.children(element).prefix(maxSearchNodes))
    }

    /// "Does this element carry text?" — answered by capability, not role,
    /// since a third-party app's canvas/text role is unknowable in advance.
    private static func isTextual(_ element: AXUIElement) -> Bool {
        for attribute in [
            kAXSelectedTextRangeAttribute,
            kAXVisibleCharacterRangeAttribute,
            kAXNumberOfCharactersAttribute,
        ] {
            if AX.hasAttribute(element, attribute) { return true }
        }
        return false
    }

}
