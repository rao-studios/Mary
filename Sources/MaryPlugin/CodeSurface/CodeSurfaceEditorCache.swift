//
//  CodeSurfaceEditorCache.swift
//  MaryPlugin
//
//  THE ONE EXPENSIVE STEP OF A CODE-SURFACE READ, PAID ONCE PER WINDOW.
//
//  `CodeSurfaceAX`'s own header records the measurement this file exists for:
//  every attribute read against a located editor costs ~0.1–0.2 ms, and the
//  TREE WALK that locates it costs ~330 ms. That asymmetry was survivable
//  while the only callers were `CodeSurfaceAdapter`'s Skill handlers — a
//  third of a second inside a tool call the user asked for is invisible
//  beside the model round-trip that requested it. It is not survivable on a
//  poll: a standing ambient contribution re-walking Xcode's window every few
//  seconds would spend a third of a second of another process's main thread
//  on every tick, forever, for an answer that almost never changes.
//
//  WHAT ACTUALLY CHANGES, AND WHAT DOESN'T. The editor ELEMENT is stable —
//  Xcode reuses one `AXTextArea` across file switches within a window, so a
//  cached element keeps answering for the next file the same way it answered
//  for the last. What is NOT stable is the WINDOW it lives in and the PROCESS
//  that owns it, and those are exactly the two things a cache here can get
//  wrong in a way that matters: a stale element belonging to a closed window
//  answers nothing (harmless), but one belonging to a DIFFERENT window
//  answers confidently about the wrong file (not harmless at all).
//
//  SO THE KEY IS (pid, focused window) AND THE ENTRY IS RE-PROVED EVERY TIME.
//  Three cheap checks stand between a cached element and its reuse — same
//  process, same window element, and the element still answering one of the
//  roles the package declared. All three together cost one AX attribute read,
//  which is the price of being sure rather than the price of assuming. Any of
//  them failing drops the entry and re-walks.
//
//  ONE ENTRY, NOT A MAP. The callers all ask about the front editor; a per-pid
//  map would hold elements for windows nobody is looking at and give a second
//  thing to invalidate for no measured gain. The one cost of that choice is
//  that a Skill call naming a BACKGROUND editor evicts the foreground entry the
//  observer keeps warm, and the next poll re-walks once. Measured against the
//  alternative — a map whose extra entries would each need the same liveness
//  re-proof — that is the cheaper wrong.
//
//  `frontSurface` IS THE SECOND CALLER, AND IT IS NOT THE SAME QUESTION AS
//  `CodeSurfaceAX.frontSurface`. That one walks EVERY window of the process in
//  `kAXWindows` order and returns the first that holds an editor;
//  this one asks `kAXFocusedWindow` and walks only that. Measured live against
//  a two-window Xcode, the focused window IS `kAXWindows[0]` — printed by
//  `--dispatch-code-surface --debug-windows` rather than assumed — so in the
//  ordinary case the two name the same surface, and after the first call this
//  one names it without walking at all. Where they
//  can diverge is a focused window with NO editor — a Preferences sheet, an
//  Organizer — and there the all-windows path would keep looking and find a
//  real editor behind it. That case falls back to the full walk rather than
//  answering "no source file open," so nothing a caller could see gets worse.
//  STAGED LIVE, not only unit-tested: with Xcode's Settings window focused and
//  three editor windows behind it, `read_buffer` still answered out of the
//  first of them. The fallback's answer is NOT cached — it belongs to a window
//  that is not the focused one, which is the exact thing this cache's key
//  refuses to hold — so that state keeps paying the old ~130 ms per call. That
//  is not a regression; it is precisely what every call used to cost.
//
//  AND FOR THE THREE READERS THE FOCUSED WINDOW IS THE STRICTER ANSWER, not
//  merely the cheaper one. `read_selection` and `replace_selection` read
//  `kAXSelectedTextRange`, which is a statement about where the user is typing;
//  answering it out of a window that is merely first in z-order while a
//  different one holds focus would report a selection nobody is making. The
//  fallback preserves the old reach; the primary path narrows to the window
//  that can actually own a caret.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public enum CodeSurfaceEditorCache {

    private struct Entry {
        var pid: pid_t
        var window: AXUIElement
        var editor: AXUIElement
        /// The role the cached element answered when it was located. Re-read
        /// on every hit: an element whose role has changed, or which has died
        /// with its window, is not this editor any more.
        var role: String
    }

    private static let box = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    /// How many times a real tree walk has been paid. THE POINT OF THE WHOLE
    /// FILE, made measurable: a caller that polls should see this stop rising
    /// while the user stays in one window. Read by the probe's timing section
    /// and by the cache's tests.
    private static let walkCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)

    public static var walkCount: Int { walkCountBox.withLock { $0 } }

    public static func resetWalkCount() { walkCountBox.withLock { $0 = 0 } }

    /// The text element of `window`, from the cache when the cache can still
    /// prove it, and from a fresh walk otherwise.
    ///
    /// `locate` and `role` are injected so the cache's own behaviour — hit,
    /// miss on a new window, miss on a dead element — is testable without an
    /// editor open. Both defaults reach Accessibility, which is the one thing
    /// this file does not itself do and the one thing a test process has no
    /// honest way to provide.
    public static func editor(
        pid: pid_t,
        window: AXUIElement,
        registration: CodeSurfaceRegistration,
        locate: (AXUIElement, CodeSurfaceRegistration) -> AXUIElement? =
            { CodeSurfaceAX.editor(in: $0, registration: $1) },
        role: (AXUIElement) -> String? = { AX.string($0, kAXRoleAttribute) },
        focused: (AXUIElement) -> Bool = { CodeSurfaceAX.isFocused($0) }
    ) -> AXUIElement? {
        if let cached = box.withLock({ $0 }),
           cached.pid == pid,
           CFEqual(cached.window, window),
           // THE LIVENESS PROBE, and it is one attribute read. A window that
           // closed leaves an element that answers nothing; a pane that was
           // replaced leaves one answering a different role. Both come back
           // here as "not the editor" rather than as a confident read of a
           // file the user is no longer in.
           let live = role(cached.editor),
           live == cached.role,
           registration.editorRoleNames.contains(live),
           // A SPLIT EDITOR can keep the same window and swap which pane
           // holds the caret. Largest-wins would keep the cached (often
           // larger) sibling; when the package prefers focus, an unfocused
           // cache entry is as stale as a dead role.
           !registration.preferFocusedElement || focused(cached.editor) {
            return cached.editor
        }
        walkCountBox.withLock { $0 += 1 }
        guard let editor = locate(window, registration),
              let role = role(editor)
        else {
            // A WINDOW WITH NO EDITOR CLEARS THE ENTRY. Leaving the previous
            // window's element in place would let the next poll — which may
            // land on that same window again — hit a cache that outlived the
            // reason it was true.
            box.withLock { $0 = nil }
            return nil
        }
        box.withLock { $0 = Entry(pid: pid, window: window, editor: editor, role: role) }
        return editor
    }

    // MARK: - The front surface, cached

    /// The surface a Skill call means when it names no document — the focused
    /// window's editor, through the cache, with the all-windows walk kept
    /// behind it for the cases the focused window cannot answer.
    ///
    /// See this file's header for why the focused window is both the cheaper
    /// and the stricter reading of "the front editor", and what the fallback
    /// is for. `locateAll` is injected on `editor(pid:window:…)`'s own
    /// precedent so the fallback branch is reachable from a test that has no
    /// editor open.
    public static func frontSurface(
        pid: pid_t,
        registration: CodeSurfaceRegistration,
        focusedWindow: (AXUIElement) -> AXUIElement? =
            { AX.element($0, kAXFocusedWindowAttribute) },
        locate: (AXUIElement, CodeSurfaceRegistration) -> AXUIElement? =
            { CodeSurfaceAX.editor(in: $0, registration: $1) },
        role: (AXUIElement) -> String? = { AX.string($0, kAXRoleAttribute) },
        focused: (AXUIElement) -> Bool = { CodeSurfaceAX.isFocused($0) },
        locateAll: (pid_t, CodeSurfaceRegistration) -> CodeSurfaceAX.Surface? =
            { CodeSurfaceAX.frontSurface(pid: $0, registration: $1) }
    ) -> CodeSurfaceAX.Surface? {
        // NO `AXIsProcessTrusted` GATE OF ITS OWN, deliberately. Without the
        // grant `kAXFocusedWindow` answers `kAXErrorAPIDisabled` and therefore
        // nil, which lands on the fallback — and `CodeSurfaceAX.frontSurface`
        // holds the real guard, in the one place that would otherwise start a
        // tree walk. Leaving it out here is also what lets a test drive the
        // focused-window branch at all, since a test runner is never trusted.
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, CodeSurfaceAX.messagingTimeout)
        guard let window = focusedWindow(application),
              let editor = editor(
                pid: pid, window: window, registration: registration,
                locate: locate, role: role, focused: focused)
        else { return locateAll(pid, registration) }

        // ORDINAL 1, AND IT IS NOT AN APPROXIMATION OF THE WALK'S OWN COUNT.
        // `CodeSurfaceAX.surfaces` numbers the windows that hold editors in
        // reading order, and this function returns exactly one surface — the
        // front one — so its ordinal among front surfaces is 1. The number is
        // only ever read by `documentKey`'s fallback, for a document with no
        // `AXDocument` at all (a file never saved), where it names a window
        // rather than a path and `CodeSurfaceWriter.fileURL` correctly refuses
        // it either way.
        return CodeSurfaceAX.Surface(
            window: window,
            editor: editor,
            documentKey: CodeSurfaceAX.documentKey(
                of: window, registration: registration, ordinal: 1),
            title: AX.string(window, kAXTitleAttribute) ?? "",
            ordinal: 1)
    }

    /// Drop whatever is held. Called when the observer stops, so a cache
    /// cannot outlive the poll that maintains it.
    public static func invalidate() {
        box.withLock { $0 = nil }
    }

    /// Whether anything is currently cached — the tests' window onto the
    /// invalidation paths, which are otherwise only visible as a walk count.
    public static var isPrimed: Bool { box.withLock { $0 != nil } }
}
