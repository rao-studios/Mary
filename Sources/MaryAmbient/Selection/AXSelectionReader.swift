//
//  AXSelectionReader.swift
//  MaryBrain
//
//  WHAT: Shared source-selection ability — exact AX element → canonical selection packet.
//  OUT:  SelectionHandoffPublisher. Splits: +Models / +Reads / +ElementResolution
//  PIN:  focusedSelectionSample is mutation authority. sourceSelectionSample is evidence-only descent.
//

import AppKit
import ApplicationServices
import MaryFoundation
import Foundation

public enum AXSelectionReader {

    /// Which AX representation actually supplied the selected characters. Canvas applications
    /// frequently expose a range before they expose `AXSelectedText`, so the attribute name
    /// alone is not a correctness boundary.
    public static func read(pid: pid_t) -> Reading? {
        guard AppAutomationGate.accessibilityBlock() == nil else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Mirrors `PagesAX.read(pid:)`'s own note: this governs the APPLICATION element only
        // (`AXUIElement.h` — "setting the timeout on another accessibility object sets it only for
        // that object"); a busy app must not stall the poll loop.
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let resolved = textElement(of: app) else { return nil }
        let element = resolved.element
        let role = copyString(element, kAXRoleAttribute)
        guard !isSecureField(role: role) else { return nil }

        switch selectionState(of: element, role: role, resolution: resolved.resolution) {
        case .selected(let reading): return reading
        case .caret, .unreadableNonemptyRange, .ambiguousSelection, .unavailable:
            return nil
        }
    }

    /// Read the AX element the application currently names as focused, with no main-window
    /// descent or role preference. This is the selection ability's authority path: an app owns
    /// its focused editing element even if a canvas exposes it as an unexpected role.
    public static func focusedSelectionSample(
        pid: pid_t, messagingTimeout: TimeInterval = 0.25
    ) -> FocusedSelectionSample {
        let capturedAt = Date()
        guard let focused = focusedElement(pid: pid, messagingTimeout: messagingTimeout) else {
            return FocusedSelectionSample(
                processID: pid, state: .unavailable, capturedAt: capturedAt)
        }
        return FocusedSelectionSample(
            processID: pid,
            state: selectionState(of: focused, resolution: .focusedElement),
            capturedAt: capturedAt,
            sourceSurfaceID: sourceSurfaceID(of: focused),
            sourceCharacterCount: characterCount(of: focused),
            editability: editability(of: focused))
    }

    /// THE TYPING GATE'S SAMPLE — focused element first, then a bounded main-window descent. A
    /// secure field never supplies the surface, on either path.
    public static func focusedWritableSurfaceSample(
        pid: pid_t, messagingTimeout: TimeInterval = 0.25
    ) -> FocusedSelectionSample {
        let capturedAt = Date()
        guard AppAutomationGate.accessibilityBlock() == nil else {
            return FocusedSelectionSample(
                processID: pid, state: .unavailable, capturedAt: capturedAt)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(messagingTimeout))

        // The exact focused element keeps first claim — when it proves a text
        // capability, this sample is byte-equivalent to the strict one.
        if let focused = copyElement(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, Float(messagingTimeout))
            let role = copyString(focused, kAXRoleAttribute)
            let state = selectionState(of: focused, role: role, resolution: .focusedElement)
            switch state {
            case .selected, .caret, .unreadableNonemptyRange, .ambiguousSelection:
                return FocusedSelectionSample(
                    processID: pid,
                    state: state,
                    capturedAt: capturedAt,
                    sourceSurfaceID: sourceSurfaceID(of: focused),
                    sourceCharacterCount: characterCount(of: focused),
                    editability: editability(of: focused))
            case .unavailable:
                break
            }
        }

        // Focus names a canvas/toolbar/nothing: one bounded descent for the
        // window's text surface. The discovered element is weaker evidence
        // than app-named focus, and the sample says so.
        guard let resolved = textElement(of: app) else {
            return FocusedSelectionSample(
                processID: pid, state: .unavailable, capturedAt: capturedAt)
        }
        let role = copyString(resolved.element, kAXRoleAttribute)
        guard !isSecureField(role: role) else {
            return FocusedSelectionSample(
                processID: pid, state: .unavailable, capturedAt: capturedAt)
        }
        let state = selectionState(
            of: resolved.element, role: role, resolution: resolved.resolution)
        return FocusedSelectionSample(
            processID: pid,
            state: state,
            capturedAt: capturedAt,
            sourceSurfaceID: sourceSurfaceID(of: resolved.element),
            sourceCharacterCount: characterCount(of: resolved.element),
            editability: editability(of: resolved.element),
            sourceEvidence: .discoveredDescendant)
    }

    /// Capture a direct source selection without weakening the typing target contract. The
    /// focused element gets the first, exact attempt. A discovered descendant can establish a
    /// positive selection, but can never establish a caret. If no positive evidence is found.
    public static func sourceSelectionSample(
        pid: pid_t, messagingTimeout: TimeInterval = 0.25
    ) -> FocusedSelectionSample {
        let capturedAt = Date()
        let discoveryDeadline = capturedAt.addingTimeInterval(sourceSelectionSearchBudget)
        guard AppAutomationGate.accessibilityBlock() == nil else {
            return FocusedSelectionSample(
                processID: pid, state: .unavailable, capturedAt: capturedAt)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(messagingTimeout))
        let focused = copyElement(app, kAXFocusedUIElementAttribute)
        let mainWindow = copyElement(app, kAXMainWindowAttribute)

        var focusedState: SelectionState?
        var discovery = SelectionDiscovery()
        if let focused {
            AXUIElementSetMessagingTimeout(focused, Float(messagingTimeout))
            let state = selectionState(of: focused, resolution: .focusedElement)
            focusedState = state
            if !shouldSearchDescendants(afterFocusedState: state) {
                // A readable exact selection and an unreadable exact nonempty range are both source
                // ownership. The latter must reach the handoff as explicit unpublishable evidence instead
                // of being replaced by a descendant selected through AX tree order.
                return selectionSample(
                    processID: pid, state: state, capturedAt: capturedAt,
                    fallbackElement: focused,
                    sourceEvidence: .exactElement)
            }
            collectSelectionEvidence(
                of: focused,
                includeRoot: false,
                messagingTimeout: messagingTimeout,
                deadline: discoveryDeadline,
                resolution: .mainWindowDescent,
                into: &discovery)
        }

        // AX may put the actual text surface outside the canvas container it calls focused. Avoid
        // rewalking the same object, but otherwise add bounded, positive candidates from the main
        // window.
        if let mainWindow,
           focused.map({ !CFEqual($0, mainWindow) }) ?? true,
           !discovery.isAmbiguous {
            collectSelectionEvidence(
                of: mainWindow,
                includeRoot: true,
                messagingTimeout: messagingTimeout,
                deadline: discoveryDeadline,
                resolution: .mainWindowDescent,
                into: &discovery)
        }

        switch discovery.outcome {
        case .selected(let evidence):
            guard case .selected(let reading) = evidence.state else { break }
            return selectionSample(
                processID: pid,
                state: evidence.state,
                capturedAt: capturedAt,
                fallbackElement: evidence.element,
                reading: reading,
                sourceEvidence: .discoveredDescendant)
        case .unreadable(let evidence):
            return selectionSample(
                processID: pid,
                state: evidence.state,
                capturedAt: capturedAt,
                fallbackElement: evidence.element,
                sourceEvidence: .discoveredDescendant)
        case .ambiguous:
            // A focused canvas plus two positive descendants has no source ownership signal.
            return FocusedSelectionSample(
                processID: pid, state: .ambiguousSelection, capturedAt: capturedAt,
                sourceEvidence: .discoveredDescendant)
        case .none:
            break
        }
        if let focused, let focusedState {
            return selectionSample(
                processID: pid, state: focusedState, capturedAt: capturedAt,
                fallbackElement: focused, sourceEvidence: .exactElement)
        }
        return FocusedSelectionSample(
            processID: pid, state: .unavailable, capturedAt: capturedAt)
    }

    /// An exact positive source result owns the interaction even if text
    /// hydration failed. Only a caret or absent focused data leaves room for a
    /// bounded canvas search to find positive descendant evidence.
    public static func shouldSearchDescendants(afterFocusedState state: SelectionState) -> Bool {
        switch state {
        case .caret, .unavailable:
            return true
        case .selected, .unreadableNonemptyRange, .ambiguousSelection:
            return false
        }
    }

    public static func focusedSelectionState(
        pid: pid_t, messagingTimeout: TimeInterval = 0.25
    ) -> SelectionState {
        guard let focused = focusedElement(pid: pid, messagingTimeout: messagingTimeout) else {
            return .unavailable
        }
        return selectionState(of: focused, resolution: .focusedElement)
    }

    /// Build a sample from a state while preserving the exact descendant that supplied positive
    /// evidence.
    private static func selectionSample(
        processID: pid_t,
        state: SelectionState,
        capturedAt: Date,
        fallbackElement: AXUIElement? = nil,
        reading suppliedReading: Reading? = nil,
        sourceEvidence: AmbientSelectionSourceEvidence = .exactElement
    ) -> FocusedSelectionSample {
        let reading: Reading?
        if let suppliedReading {
            reading = suppliedReading
        } else if case .selected(let selected) = state {
            reading = selected
        } else {
            reading = nil
        }
        return FocusedSelectionSample(
            processID: processID,
            state: state,
            capturedAt: capturedAt,
            sourceSurfaceID: reading?.sourceSurfaceID
                ?? fallbackElement.map { sourceSurfaceID(of: $0) },
            sourceCharacterCount: fallbackElement.flatMap { characterCount(of: $0) },
            editability: reading?.editability
                ?? fallbackElement.map { editability(of: $0) }
                ?? .unknown,
            sourceEvidence: sourceEvidence)
    }

    /// Exposed for source observers that must bind their notification to the actual focused
    /// text element. The timeout is set on BOTH the app and child because Accessibility does
    /// not inherit an app timeout to child elements.
    public static func focusedElement(
        pid: pid_t, messagingTimeout: TimeInterval = 0.25
    ) -> AXUIElement? {
        guard AppAutomationGate.accessibilityBlock() == nil else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(messagingTimeout))
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, Float(messagingTimeout))
        return focused
    }

    /// Best-effort source-surface fingerprint. AX elements are CF objects, so
    /// this is not serialized or treated as a document offset; it only scopes
    /// a same-process selection/caret handoff while the object is alive.
    public static func sourceSurfaceID(of element: AXUIElement) -> UInt {
        UInt(CFHash(element))
    }

    /// `kAXNumberOfCharacters` is expressed in Accessibility's UTF-16 coordinate space. It is
    /// source metadata only; callers must never pair it with an unrelated application body
    /// merely because the counts happen to be close.
    public static func characterCount(of element: AXUIElement) -> Int? {
        guard let number = AX.number(element, kAXNumberOfCharactersAttribute),
              number.intValue >= 0
        else { return nil }
        return number.intValue
    }

    /// Read the source element's declared mutation capability without probing
    /// it. Missing `AXEditable` is common on canvas editors, so absence means
    /// `unknown`, never a guessed yes or no.
    public static func editability(of element: AXUIElement) -> AmbientSelectionEditability {
        // ApplicationServices does not surface a Swift constant for this
        // documented AX attribute on every SDK, so keep the stable AX name
        // literal alongside the other string-backed role checks in this file.
        guard let ref = AX.attribute(element, "AXEditable")
        else { return .unknown }
        if let value = ref as? Bool {
            return value ? .editable : .readOnly
        }
        if let value = ref as? NSNumber {
            return value.boolValue ? .editable : .readOnly
        }
        return .unknown
    }

    /// A password field, best-effort. A custom-rendered secure field that doesn't expose the
    /// standard AX role slips past this.
    public static let secureTextFieldRole = "AXSecureTextField"

    public static func isSecureField(role: String?) -> Bool {
        role == secureTextFieldRole
    }

}
