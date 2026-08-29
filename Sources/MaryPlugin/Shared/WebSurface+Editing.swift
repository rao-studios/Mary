//
//  WebSurface+Editing.swift
//  MaryPlugin
//
//  FINDING THE EDITOR, PUTTING THE CARET IN IT, AND PLACING TEXT.
//
//  Every rule below is a measurement the predecessor paid for against a live
//  browser, and each is a place where the obvious implementation is silently
//  wrong — not slow, not throwing, wrong in a way that produces a plausible
//  result. They are carried over verbatim in substance because the browsers
//  they were measured against have not changed their minds.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryFoundation

public extension WebSurface {

    // MARK: - Finding the editor

    /// Text-shaped AND writable. A page is full of read-only text; only a
    /// surface that answers a selected-range attribute and does not refuse
    /// the setters can take a paste.
    static func isEditableText(_ element: AXUIElement) -> Bool {
        guard AX.hasAttribute(element, kAXSelectedTextRangeAttribute) else { return false }
        let role = AX.string(element, kAXRoleAttribute) ?? ""
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
        else { return false }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // Some web surfaces refuse the value setter but still take keys; a
        // settable selected range is the weaker but real second signal.
        var rangeSettable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success
            && rangeSettable.boolValue
    }

    /// The editable surfaces inside the PAGE.
    ///
    /// SCOPED TO THE WEB AREA, and that scope is load-bearing: the window
    /// also holds the address bar, which is an `AXTextField` reporting itself
    /// perfectly settable — as `WebSurface+Navigation` depends on. A
    /// whole-window search hands back the omnibox, and the text goes into the
    /// URL.
    ///
    /// Text AREAS sort first: a rich editor's surface is an area, while a
    /// text FIELD inside a page is almost always its search box.
    static func editableSurfaces(
        in application: AXUIElement, strategy: WebAreaStrategy = .first
    ) -> [AXUIElement] {
        guard let area = webArea(in: application, strategy: strategy) else { return [] }
        var found: [AXUIElement] = []
        AXTreeWalker.walk(from: area, budget: pageBudget) { element, _ in
            guard isEditableText(element) else { return }
            guard !found.contains(where: { CFEqual($0, element) }) else { return }
            found.append(element)
        }
        return found.sorted { lhs, _ in
            AX.string(lhs, kAXRoleAttribute) == kAXTextAreaRole as String
        }
    }

    /// MEASURED: a freshly loaded page has NO editable surface yet. The title
    /// lands well before a JavaScript editor has built itself, and a
    /// single-shot search right after load found zero candidates while the
    /// same search against a settled tab found the text area every time.
    ///
    /// A deadline rather than a longer sleep: a fast machine is not punished,
    /// and a slow build is not mistaken for a page without an editor.
    static func awaitEditableSurface(
        in application: AXUIElement,
        consentLabels: Set<String> = [],
        timeout: TimeInterval = 12,
        strategy: WebAreaStrategy = .first,
        hints: [String] = []
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return nil }
            if !consentLabels.isEmpty {
                dismissConsentBanner(in: application, labels: consentLabels)
            }
            let surfaces = editableSurfaces(in: application, strategy: strategy)
            if let chosen = choose(from: surfaces, hints: hints) { return chosen }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
        } while Date() < deadline
        return nil
    }

    /// The editor a declaration named, or the first one.
    ///
    /// A HINT IS A PREFERENCE, NOT A FILTER, and that is the whole design. A
    /// site renames its editor and a hint that filtered would turn a working
    /// lane into "I couldn't find the editor on the page" — a total failure
    /// caused by a cosmetic change somewhere else. Preferring instead degrades
    /// to exactly the behaviour that existed before hints did.
    ///
    /// Matched against what the element says about ITSELF — title, description,
    /// help — never its contents: an editor's value is the user's text, and a
    /// hint that matched it would pick whichever field happened to contain the
    /// word.
    static func choose(from surfaces: [AXUIElement], hints: [String]) -> AXUIElement? {
        guard !surfaces.isEmpty else { return nil }
        guard !hints.isEmpty else { return surfaces.first }
        let wanted = hints.map { $0.lowercased() }.filter { !$0.isEmpty }
        let hinted = surfaces.first { element in
            let described = [
                AX.string(element, kAXTitleAttribute),
                AX.string(element, kAXDescriptionAttribute),
                AX.string(element, kAXHelpAttribute),
                AX.string(element, kAXPlaceholderValueAttribute),
            ].compactMap { $0?.lowercased() }
            return described.contains { text in wanted.contains(where: text.contains) }
        }
        return hinted ?? surfaces.first
    }

    /// Press a consent button by its declared label — a cookie notice sitting
    /// over the page it is trying to read. The labels come from a package,
    /// never from a table here: which words a site puts on its own button is
    /// exactly the kind of fact a declaration should carry.
    ///
    /// Best effort by contract; a banner that is not there is not a failure.
    @discardableResult
    static func dismissConsentBanner(
        in application: AXUIElement, labels: Set<String>
    ) -> Bool {
        guard !labels.isEmpty, let window = focusedWindow(in: application) else { return false }
        let wanted = Set(labels.map { $0.lowercased() })
        var target: AXUIElement?
        AXTreeWalker.walk(from: window, budget: pageBudget) { element, _ in
            guard target == nil else { return }
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            guard role == kAXButtonRole as String || role == "AXLink" else { return }
            // TITLE, THEN DESCRIPTION, THEN VALUE — the measured ladder. A
            // consent button names itself in whichever of the three its
            // framework favours, and Chrome and Safari do not agree.
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                guard let text = AX.string(element, attribute)?.lowercased(),
                      wanted.contains(text) else { continue }
                target = element
                return
            }
        }
        guard let target else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    // MARK: - Focus

    /// Focus the element and PROVE it.
    ///
    /// MEASURED, and the subtlest finding of the whole exercise: setting
    /// `kAXFocused` returns `.success` on a rich editor's proxy text area
    /// WITHOUT the editor taking keyboard focus. On a settled tab that looks
    /// fine — focus was already there, so the setter was a no-op reporting
    /// success. On a COLD page it lies: the select-all that follows selects
    /// nothing and the paste lands in the middle of what was already there.
    /// The predecessor caught it as a compile error reading `'edvoid' :
    /// syntax error` — the tail of the old text fused to the head of the new.
    ///
    /// So the setter's return value is not evidence. Read the application's
    /// focused element back and compare identity.
    static func takeFocus(
        _ element: AXUIElement, in application: AXUIElement, pid: pid_t
    ) async -> Bool {
        _ = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(200))
        if holdsFocus(element, in: application) { return true }

        // The fallback is the same ladder `PageElementActions.press` climbs:
        // when an element's own affordance does not take, a real click at its
        // measured frame does. Reusing that keeps ONE definition of "click
        // the thing I can see" rather than a second CGEvent site here.
        guard let caret = AX.frame(of: element), caret.height > 1 else { return false }
        // CLAMPED INTO THE PAGE, because a caret proxy is a wide one-line
        // sliver that tracks the insertion point: on a scrolled window it can
        // report a point outside the page, and a click there lands on the
        // browser's own toolbar. Outside the page this refuses rather than
        // clicking blind.
        let point = CGPoint(x: (caret.minX + 8).rounded(), y: caret.midY.rounded())
        if let bounds = visiblePageFrame(in: application),
           bounds.width > 1, bounds.height > 1,
           !bounds.insetBy(dx: 2, dy: 2).contains(point) {
            return false
        }
        guard PageElementActions.click(at: point, pid: pid) else { return false }
        try? await Task.sleep(for: .milliseconds(250))
        return holdsFocus(element, in: application)
    }

    static func holdsFocus(_ element: AXUIElement, in application: AXUIElement) -> Bool {
        guard let focused = AX.element(application, kAXFocusedUIElementAttribute)
        else { return false }
        return CFEqual(focused, element)
    }

    // MARK: - Placing text

    /// Select everything, then paste — with the user's clipboard saved and
    /// put back.
    ///
    /// A PASTE, NOT TYPING, and this is a decision rather than a shortcut. A
    /// code editor auto-indents and auto-closes brackets, so feeding source
    /// through the typer a chunk at a time would have every `{` grow a
    /// phantom `}` and every newline re-indent what came before. A paste is
    /// one atomic insert the editor leaves alone.
    ///
    /// Reserved for surfaces the caller KNOWS are fresh — a template, a
    /// document created seconds ago. Anything else gets `insertAtCaret`.
    @MainActor
    static func replaceAll(with text: String) async -> Bool {
        await withClipboardBracket(text: text) {
            guard KeyChordPress.press(key: .a, modifiers: [.command]) else { return false }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return false }
            guard !Task.isCancelled else { return false }
            return KeyChordPress.press(key: .v, modifiers: [.command])
        }
    }

    /// Paste at the caret — `replaceAll` without the select-all, for surfaces
    /// the caller must NOT wipe.
    @MainActor
    static func insertAtCaret(_ text: String) async -> Bool {
        await withClipboardBracket(text: text) {
            KeyChordPress.press(key: .v, modifiers: [.command])
        }
    }

    /// The shared clipboard save/restore bracket around one synthetic paste.
    ///
    /// THE CLIPBOARD IS THE USER'S. Borrowing it for a paste is the price of
    /// placing text atomically; not giving it back would be taking it. The
    /// `defer` restores every representation of every item, not just the
    /// string, because a copied image put back as its text description is a
    /// loss that shows up much later.
    @MainActor
    private static func withClipboardBracket(
        text: String, paste: () async -> Bool
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        guard !Task.isCancelled else { return false }
        guard await paste() else { return false }
        // A paste raises no changeCount to wait on — settle before the defer
        // pulls the clipboard back out from under the page.
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return false }
        return true
    }
}
