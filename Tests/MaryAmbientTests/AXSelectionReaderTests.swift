import Foundation
import Testing
@testable import MaryAmbient

/// `AXSelectionReader`'s pure predicate — the IPC around it can't be
/// exercised in a test process, the same limitation `PagesAX.swift`'s own
/// header notes about itself, so this pins the one decision made without it.
@Suite struct AXSelectionReaderTests {

    @Test func secureFieldsAreSkipped() {
        #expect(AXSelectionReader.isSecureField(role: "AXSecureTextField"))
    }

    @Test func ordinaryTextRolesAreNotSkipped() {
        #expect(!AXSelectionReader.isSecureField(role: "AXTextArea"))
        #expect(!AXSelectionReader.isSecureField(role: "AXTextField"))
        #expect(!AXSelectionReader.isSecureField(role: "AXStaticText"))
        #expect(!AXSelectionReader.isSecureField(role: nil))
    }

    @Test func discoveredSelectionRequiresOneDistinctAXSurface() {
        #expect(AXSelectionReader.discoveredSelectionDisposition(for: []) == .none)
        #expect(AXSelectionReader.discoveredSelectionDisposition(for: [
            .selected(surfaceID: 101),
            // The main-window walk can revisit the focused-subtree leaf.
            .selected(surfaceID: 101),
        ]) == .selected)
        #expect(AXSelectionReader.discoveredSelectionDisposition(for: [
            .unreadableNonemptyRange(surfaceID: 101),
        ]) == .unreadableNonemptyRange)
    }

    @Test func competingDescendantsAlwaysAbstain() {
        // Tree order cannot distinguish a stale title/control selection from
        // a visible body highlight. A nonempty body range that cannot be read
        // is competing evidence too; it must never cause the readable title
        // leaf to win by accident.
        #expect(AXSelectionReader.discoveredSelectionDisposition(for: [
            .selected(surfaceID: 101),
            .selected(surfaceID: 202),
        ]) == .ambiguous)
        #expect(AXSelectionReader.discoveredSelectionDisposition(for: [
            .selected(surfaceID: 101),
            .unreadableNonemptyRange(surfaceID: 202),
        ]) == .ambiguous)
    }

    @Test func anExactUnreadableRangeDoesNotAuthorizeADescendantWalk() {
        // The exact focused element can prove a real Pages/TextEdit selection
        // even when its text channel is unavailable. A tree walk after that
        // would be free to substitute an unrelated readable title/control.
        #expect(!AXSelectionReader.shouldSearchDescendants(
            afterFocusedState: .unreadableNonemptyRange(range: 40..<55)))
        #expect(!AXSelectionReader.shouldSearchDescendants(
            afterFocusedState: .selected(.init(text: "selected"))))
        #expect(!AXSelectionReader.shouldSearchDescendants(
            afterFocusedState: .ambiguousSelection))
        #expect(AXSelectionReader.shouldSearchDescendants(
            afterFocusedState: .caret(range: 40..<40)))
        #expect(AXSelectionReader.shouldSearchDescendants(
            afterFocusedState: .unavailable))
    }
}
