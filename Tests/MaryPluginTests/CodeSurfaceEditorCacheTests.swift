//
//  CodeSurfaceEditorCacheTests.swift
//  MaryPluginTests
//
//  THE ONE REAL CORRECTNESS RISK IN THE STANDING CURSOR LANE, pinned.
//
//  Caching the located editor element is what makes a poll affordable at all
//  (~330 ms walked, ~0.1–0.2 ms read). What it can get WRONG is invalidation:
//  a cached element that belongs to a window the user has left answers
//  confidently about the wrong file, which is worse than answering nothing.
//  So every path that must drop the entry gets a test — a new window, a new
//  process, an element that stopped answering its role, an element whose role
//  the package no longer declares, a window with no editor in it, and an
//  explicit teardown.
//
//  ELEMENTS COME FROM `AXUIElementCreateApplication`, which mints a real,
//  CFEqual-comparable element for any pid without needing that process to
//  exist or Accessibility to be granted. That is exactly what the cache
//  compares on, so the identity half of these tests is the real thing; the
//  two Accessibility reads (locate, role) are injected, because a test runner
//  has no honest way to provide them.
//

import ApplicationServices
import Foundation
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class CodeSurfaceEditorCacheTests: XCTestCase {

    private let registration = CodeSurfaceRegistration(
        applicationID: "editor",
        bundleIdentifiers: ["com.example.editor"],
        displayName: "Editor",
        schema: PluginCodeSurfaceSchema(
            handlePrefix: "C",
            editorRoles: [.textArea],
            documentKey: .documentPathThenWindow,
            budgets: PluginProseBudgetSchema(
                wholeDocumentCharacters: 20_000,
                regionCharacters: 4_000,
                ambientExcerptCharacters: 500)))

    /// Distinct, comparable stand-ins for a window and an editor.
    private func element(_ seed: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(seed)
    }

    override func setUp() {
        super.setUp()
        CodeSurfaceEditorCache.invalidate()
        CodeSurfaceEditorCache.resetWalkCount()
    }

    override func tearDown() {
        CodeSurfaceEditorCache.invalidate()
        super.tearDown()
    }

    private func lookup(
        pid: pid_t,
        window: AXUIElement,
        editor: AXUIElement?,
        role: String? = "AXTextArea"
    ) -> AXUIElement? {
        CodeSurfaceEditorCache.editor(
            pid: pid, window: window, registration: registration,
            locate: { _, _ in editor },
            role: { _ in role })
    }

    // MARK: - The point of the whole file

    func testASecondLookAtTheSameWindowDoesNotWalkAgain() {
        let window = element(11)
        let editor = element(12)

        XCTAssertNotNil(lookup(pid: 7, window: window, editor: editor))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        for _ in 0..<20 {
            XCTAssertTrue(
                CFEqual(lookup(pid: 7, window: window, editor: editor), editor))
        }
        XCTAssertEqual(
            CodeSurfaceEditorCache.walkCount, 1,
            "twenty polls of one unchanged window must cost exactly one walk")
    }

    // MARK: - Invalidation

    func testADifferentWindowWalksAgain() {
        let first = element(11)
        let second = element(21)
        _ = lookup(pid: 7, window: first, editor: element(12))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        let relocated = element(22)
        XCTAssertTrue(CFEqual(lookup(pid: 7, window: second, editor: relocated), relocated))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 2)
    }

    /// TWO EDITORS OF THE SAME PACKAGE, or one that relaunched: the window
    /// element can compare equal across processes, so the pid is part of the
    /// key rather than an assumption.
    func testADifferentProcessWalksAgain() {
        let window = element(11)
        _ = lookup(pid: 7, window: window, editor: element(12))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        _ = lookup(pid: 8, window: window, editor: element(13))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 2)
    }

    /// THE LIVENESS PROBE. A window that closed leaves an element that
    /// answers nothing — the entry must not survive that.
    func testAnElementThatStoppedAnsweringItsRoleWalksAgain() {
        let window = element(11)
        _ = lookup(pid: 7, window: window, editor: element(12))
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        _ = CodeSurfaceEditorCache.editor(
            pid: 7, window: window, registration: registration,
            locate: { _, _ in self.element(14) },
            role: { _ in nil })
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 2)
    }

    /// A PANE THAT WAS REPLACED answers a DIFFERENT role. Same verdict:
    /// this is not that editor any more.
    func testAnElementWhoseRoleChangedWalksAgain() {
        let window = element(11)
        _ = lookup(pid: 7, window: window, editor: element(12), role: "AXTextArea")
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        _ = lookup(pid: 7, window: window, editor: element(12), role: "AXTextField")
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 2)
    }

    /// A WINDOW WITH NO EDITOR CLEARS THE ENTRY rather than leaving the
    /// previous window's element behind for the next poll to find.
    func testAWindowWithNoEditorLeavesNothingPrimed() {
        _ = lookup(pid: 7, window: element(11), editor: element(12))
        XCTAssertTrue(CodeSurfaceEditorCache.isPrimed)

        XCTAssertNil(lookup(pid: 7, window: element(21), editor: nil))
        XCTAssertFalse(CodeSurfaceEditorCache.isPrimed)
    }

    func testInvalidateDropsTheEntry() {
        let window = element(11)
        let editor = element(12)
        _ = lookup(pid: 7, window: window, editor: editor)
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 1)

        CodeSurfaceEditorCache.invalidate()
        XCTAssertFalse(CodeSurfaceEditorCache.isPrimed)

        _ = lookup(pid: 7, window: window, editor: editor)
        XCTAssertEqual(CodeSurfaceEditorCache.walkCount, 2)
    }
}
