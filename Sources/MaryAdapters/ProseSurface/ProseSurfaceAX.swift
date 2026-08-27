//
//  ProseSurfaceAX.swift
//  MaryAdapters
//
//  READING AND WRITING AN APPLICATION'S TEXT THROUGH ACCESSIBILITY — with no
//  application named anywhere in this file.
//
//  This is the compiled half of the prose-surface lane. It knows how to walk a
//  window to a text element, read the whole string out of it, select a range
//  and replace that selection. What it does NOT know is which role to descend
//  to, how a document is identified, or which chord makes a new one: a
//  package declares those in its `proseSurface` block and they arrive here as
//  a `ProseSurfaceRegistration`.
//
//  THE FAMILY THIS SERVES, stated precisely, because the boundary is real and
//  was learned expensively. An AppKit editor that exposes its whole document
//  through ONE text element — a stock `NSTextView`, which is what TextEdit is
//  — reads and writes correctly here. A PAGE-PARTITIONED editor does not:
//  Bonnie demoted exactly this write path to a fallback for Pages after
//  measuring the failure, and its note is worth carrying because the shape
//  repeats. Pages models a document as pages (3,635 characters on page one,
//  1,627 on page two, measured), its accessibility layer is a canvas tree, and
//  two elements held ONE page between them — so a passage crossing a page seam
//  was `.notFound` BY CONSTRUCTION. Single-line edits worked and
//  multi-paragraph ones never could.
//
//  AND THE FIX IS NOT MORE ELEMENTS. Enumerating siblings to reassemble pages,
//  normalizing line breaks with an offset map back into some other string,
//  matching short anchors instead of verbatim ones — all of it is machinery
//  for making a SECOND string agree with the first. Do not build it here. An
//  application whose document is not one element joins Mary through a
//  different declaration, not through a cleverer walk.
//
//  THE DECISIONS ARE NOT HERE. Accessibility cannot be exercised in a test
//  process, so which element and which range live in `ProseWriteLocator`,
//  which is pure and table-tested. What follows is a fixed sequence of calls
//  with nothing to choose.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient
import MaryFoundation

public enum ProseSurfaceAX {

    /// Long enough for a large document to come across the boundary, short
    /// enough that a wedged application does not hold a turn. Bonnie measured
    /// its write path against the same order of magnitude.
    static let messagingTimeout: Float = 2.0

    /// The most text this lane will pull across the boundary in one read.
    /// A runaway element cannot drag an unbounded copy into Mary's memory; a
    /// passage past the cap is simply not found, which is the honest answer
    /// rather than a wrong one.
    public static let bodyCap = 500_000

    // MARK: - Finding the surface

    /// One open window of an application, with the text element inside it.
    public struct Surface: Sendable {
        /// The window element, for titles and raising.
        public let window: AXUIElement
        /// The text element the document lives in.
        public let editor: AXUIElement
        /// This application's own stable name for the document, per its
        /// declared `documentKey` rule.
        public let documentKey: String
        public let title: String
        /// Reading-order position among this application's windows, 1-based.
        public let ordinal: Int

        public init(
            window: AXUIElement, editor: AXUIElement,
            documentKey: String, title: String, ordinal: Int
        ) {
            self.window = window
            self.editor = editor
            self.documentKey = documentKey
            self.title = title
            self.ordinal = ordinal
        }
    }

    /// Every window of `pid` that holds text, in reading order.
    ///
    /// A window with no text element is skipped rather than reported empty:
    /// an inspector panel is not a document, and listing it would put a
    /// choice in front of the user that cannot be written to.
    public static func surfaces(
        pid: pid_t, registration: ProseSurfaceRegistration
    ) -> [Surface] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let windows = AX.children(application, kAXWindowsAttribute)

        var found: [Surface] = []
        for window in windows {
            guard let editor = editor(in: window, registration: registration) else { continue }
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            found.append(Surface(
                window: window,
                editor: editor,
                documentKey: documentKey(of: window, registration: registration, ordinal: found.count + 1),
                title: title,
                ordinal: found.count + 1))
        }
        return found
    }

    /// The surface of the FRONT window, which is what "this document" means.
    public static func frontSurface(
        pid: pid_t, registration: ProseSurfaceRegistration
    ) -> Surface? {
        surfaces(pid: pid, registration: registration).first
    }

    /// THE TEXT ELEMENT, by the roles the package declared.
    ///
    /// Roles are tried in declared order, and within a role the LARGEST
    /// element wins. An editor window commonly holds several text areas — a
    /// search field, a sidebar filter, a footer — and the document is the big
    /// one. Bonnie's equivalent picked by descent order and was correct only
    /// because the applications it named happened to expose the document
    /// first.
    static func editor(
        in window: AXUIElement, registration: ProseSurfaceRegistration
    ) -> AXUIElement? {
        var byRole: [String: [(element: AXUIElement, area: CGFloat)]] = [:]
        AXTreeWalker.walk(
            from: window,
            budget: .init(maxDepth: descentDepth, maxNodes: descentNodes)
        ) { element, _ in
            guard let role = AX.string(element, kAXRoleAttribute) else { return }
            guard registration.editorRoleNames.contains(role) else { return }
            let frame = AX.frame(of: element)
            byRole[role, default: []].append(
                (element, (frame?.width ?? 0) * (frame?.height ?? 0)))
        }
        for role in registration.editorRoleNames {
            if let best = byRole[role]?.max(by: { $0.area < $1.area }) {
                return best.element
            }
        }
        return nil
    }

    /// A window's stable name for its document, per the declared rule.
    ///
    /// `AXDocument` is a file URL and the right answer wherever it exists.
    /// MEASURED: five TextEdit windows all titled "Untitled NN" carried five
    /// distinct iCloud autosave URLs, which is exactly the case this rule
    /// exists for — titles collide constantly and URLs do not.
    ///
    /// THE ORDINAL FALLBACK IS WEAKER THAN IT LOOKS, and the probe found the
    /// case: a note created SECONDS AGO has no autosave URL yet, so it keys
    /// as `textedit:win1` until one is assigned. Within the turn that made it
    /// that is fine — the staged-surface handshake carries the identity, not
    /// this key — but an ordinal is a POSITION, and a window that moves takes
    /// its key with it. Nothing durable may be filed under one.
    static func documentKey(
        of window: AXUIElement,
        registration: ProseSurfaceRegistration,
        ordinal: Int
    ) -> String {
        if registration.documentKeyKind == .documentPathThenWindow,
           let path = AX.string(window, kAXDocumentAttribute), !path.isEmpty {
            return path
        }
        return "\(registration.applicationID):win\(ordinal)"
    }

    // MARK: - Reading

    /// The whole document, capped.
    ///
    /// `AXStringForRange` first because it is bounded — it asks for exactly
    /// the characters wanted. `kAXValue` is the SAME element's text and not a
    /// different source, so the invariant that a write re-locates in the
    /// string this element handed back holds either way; it exists because
    /// the parameterized attribute is one an application may simply not
    /// implement, and an editor that answers only `kAXValue` would otherwise
    /// be silently unreadable.
    public static func fullString(of element: AXUIElement) -> String? {
        if let total = AX.number(element, kAXNumberOfCharactersAttribute)?.intValue, total > 0 {
            var wanted = CFRange(location: 0, length: min(total, bodyCap))
            if let parameter = withUnsafePointer(to: &wanted, { AXValueCreate(.cfRange, $0) }) {
                var ref: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString,
                    parameter, &ref) == .success,
                   let text = ref as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return AX.string(element, kAXValueAttribute).map { String($0.prefix(bodyCap)) }
    }

    // MARK: - Writing

    /// Select `range` — UTF-16, in this element's own coordinates.
    ///
    /// This is half the write, and the half that makes the keystroke fallback
    /// work: once the passage is selected, typing replaces it wherever it is,
    /// so the fallback inherits all of the locating already done.
    @discardableResult
    public static func select(_ range: Range<Int>, in element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let value = withUnsafePointer(to: &cfRange, { AXValueCreate(.cfRange, $0) })
        else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Replace the current selection's text.
    ///
    /// Non-`.success` is the FALLBACK'S CUE, never an error the user hears on
    /// its own: a great many applications implement the range setter and not
    /// this one, and for those the selection above plus keystrokes is a
    /// complete write.
    @discardableResult
    public static func setSelectedText(_ text: String, in element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    /// Bring one window to the front — the fallback for a write that will not
    /// land in the background, and the reason it exists is measured rather
    /// than assumed. See `ProseSurfaceWriter`.
    @discardableResult
    public static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    /// Deep enough for a real editor hierarchy, bounded because the tree
    /// belongs to another process.
    static let descentDepth = 12
    static let descentNodes = 400
}
