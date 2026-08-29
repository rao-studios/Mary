//
//  CodeSurfaceAX.swift
//  MaryPlugin
//
//  READING AN APPLICATION'S LIVE CODE BUFFER THROUGH ACCESSIBILITY — with no
//  application named anywhere in this file.
//
//  This is the compiled half of the code-surface lane. It knows how to walk a
//  window to a text element, read the whole live buffer out of it, and read
//  the live selection. What it does NOT know is which role to descend to or
//  how a document is identified: a package declares those in its
//  `codeSurface` block and they arrive here as a `CodeSurfaceRegistration`.
//
//  READ-ONLY, DELIBERATELY — `ProseSurfaceAX`'s sibling minus its whole write
//  half. Mary has no code-writing lane (`coding.mary`'s own guardrail: never
//  type prose or synthesize an edit into a code surface), so there is no
//  `select`/`setSelectedText` here the way `ProseSurfaceAX` has.
//
//  MEASURED AGAINST XCODE'S OWN SOURCE EDITOR — the spike this file replaces
//  (`docs/…/why-does-mary-keep-mutable-rabbit.md` step 3.1, formerly
//  `Sources/Probes/AXProbe/CodeProbe.swift`): a completely standard
//  `AXTextArea`. `kAXValueAttribute` / `kAXStringForRangeParameterizedAttribute`
//  return the full, correct LIVE buffer, verified against a real
//  14K-character file. `kAXSelectedTextRangeAttribute` +
//  `kAXStringForRangeParameterizedAttribute` on that range return the exact
//  live selection. READS TRACK THE LIVE IN-MEMORY BUFFER, NOT DISK — verified
//  by typing an unsaved edit, re-reading, and confirming it showed up while
//  the file's own on-disk mtime never moved. Read latency measured at
//  ~0.1–0.2 ms per attribute; the one-time tree walk to locate the editor
//  element measured at ~330 ms, the same order as `ProseSurfaceAX`'s own
//  walk. ONE CAVEAT: a stray click can land on Xcode's jump-bar search field
//  (`AXTextField`) instead of the real editor — disambiguated by EXACT role
//  name, never by "text-shaped" alone, exactly as `ProseSurfaceAX.editor(in:
//  registration:)` already does for its own family.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient
import MaryFoundation

public enum CodeSurfaceAX {

    /// Long enough for a large buffer to come across the boundary, short
    /// enough that a wedged application does not hold a turn.
    static let messagingTimeout: Float = 2.0

    /// The most text this lane will pull across the boundary in one read.
    public static let bodyCap = 500_000

    // MARK: - Finding the surface

    /// One open window of an application, with the text element inside it.
    public struct Surface: Sendable {
        /// The window element, for titles.
        public let window: AXUIElement
        /// The text element the buffer lives in.
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

    /// Every window of `pid` that holds a code buffer, in reading order.
    public static func surfaces(
        pid: pid_t, registration: CodeSurfaceRegistration
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

    /// The surface of the FRONT window, which is what "the buffer" means with
    /// no document named.
    public static func frontSurface(
        pid: pid_t, registration: CodeSurfaceRegistration
    ) -> Surface? {
        surfaces(pid: pid, registration: registration).first
    }

    /// THE TEXT ELEMENT, by the roles the package declared.
    ///
    /// Roles are tried in declared order, and within a role the LARGEST
    /// element wins — a jump-bar search field is a real `AXTextField`, and
    /// the source buffer is the big one.
    static func editor(
        in window: AXUIElement, registration: CodeSurfaceRegistration
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
    /// `AXDocument` is a file URL and the right answer wherever it exists —
    /// MEASURED against Xcode specifically: the window's `AXDocument` is the
    /// ACTIVE FILE the editor is showing, not the project root, which is
    /// exactly the identity a live buffer read wants.
    static func documentKey(
        of window: AXUIElement,
        registration: CodeSurfaceRegistration,
        ordinal: Int
    ) -> String {
        if registration.documentKeyKind == .documentPathThenWindow,
           let path = AX.string(window, kAXDocumentAttribute), !path.isEmpty {
            return path
        }
        return "\(registration.applicationID):win\(ordinal)"
    }

    // MARK: - Reading the buffer

    /// The whole live buffer, capped.
    ///
    /// `AXStringForRange` first because it is bounded — it asks for exactly
    /// the characters wanted. `kAXValue` is the SAME element's text and not a
    /// different source, so it exists only because the parameterized
    /// attribute is one an application may simply not implement, and an
    /// editor that answers only `kAXValue` would otherwise be silently
    /// unreadable.
    public static func fullString(of element: AXUIElement) -> String? {
        if let total = characterCount(of: element), total > 0,
           let text = substring(of: element, range: 0..<min(total, bodyCap)) {
            return text
        }
        return AX.string(element, kAXValueAttribute).map { String($0.prefix(bodyCap)) }
    }

    /// The number of characters the element reports, when it answers at all.
    public static func characterCount(of element: AXUIElement) -> Int? {
        AX.number(element, kAXNumberOfCharactersAttribute)?.intValue
    }

    /// One bounded slice of the buffer, in the element's OWN character
    /// coordinates — not Swift `String` indices. Exposed so a caller can ask
    /// for a WINDOW around a selection without first materializing the whole
    /// buffer as a Swift string and searching it, which would need to
    /// reconcile two different offset spaces (AX's UTF-16-flavoured range vs.
    /// `String.Index`) for no reason: the same parameterized read answers
    /// both "give me everything" and "give me this slice."
    public static func substring(of element: AXUIElement, range: Range<Int>) -> String? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let parameter = withUnsafePointer(to: &cfRange, { AXValueCreate(.cfRange, $0) })
        else { return nil }
        return AX.parameterized(
            element, kAXStringForRangeParameterizedAttribute, parameter: parameter) as? String
    }

    // MARK: - Reading the selection

    /// The live selection, in the element's own character coordinates.
    /// Empty (zero-length) is a real, common answer — a caret with nothing
    /// highlighted — and is returned as-is rather than folded into `nil`, so
    /// a caller can tell "nothing selected" from "could not read."
    public static func selectedRange(of element: AXUIElement) -> Range<Int>? {
        AX.range(element, kAXSelectedTextRangeAttribute)
    }

    /// Deep enough for a real editor hierarchy, bounded because the tree
    /// belongs to another process.
    ///
    /// WIDER THAN `ProseSurfaceAX`'s OWN BUDGET (12/400), MEASURED. That
    /// budget is right for a plain document window; it is wrong for Xcode's,
    /// which carries a project navigator beside the editor — a real window
    /// walked at 400 nodes found 83 `AXRow`/`AXCell` pairs and 84 `AXImage`
    /// icons in the navigator alone, a breadth-first queue that exhausted the
    /// budget before ever reaching the single `AXTextArea` sitting past it,
    /// and `frontSurface` reported "no source file open" against a window
    /// showing one. `Budget.standard` (24/4000) is the ceiling
    /// `SafariWebSurface`/`ProbeShaderFeel` already ship for exactly this
    /// shape of window; adopting it here rather than inventing a third number
    /// is the same call the AXEngine's own header (see `Budget.standard`'s
    /// comment) argues for.
    static let descentDepth = AXTreeWalker.Budget.standard.maxDepth
    static let descentNodes = AXTreeWalker.Budget.standard.maxNodes
}
