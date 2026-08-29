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
//  ONE ENTRY, NOT A MAP. The caller is a poll that only ever asks about the
//  front editor; a per-pid map would hold elements for windows nobody is
//  looking at and give a second thing to invalidate for no measured gain.
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
        role: (AXUIElement) -> String? = { AX.string($0, kAXRoleAttribute) }
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
           registration.editorRoleNames.contains(live) {
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

    /// Drop whatever is held. Called when the observer stops, so a cache
    /// cannot outlive the poll that maintains it.
    public static func invalidate() {
        box.withLock { $0 = nil }
    }

    /// Whether anything is currently cached — the tests' window onto the
    /// invalidation paths, which are otherwise only visible as a walk count.
    public static var isPrimed: Bool { box.withLock { $0 != nil } }
}
