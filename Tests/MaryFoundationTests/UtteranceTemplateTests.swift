//
//  UtteranceTemplateTests.swift
//  MaryFoundationTests
//
//  WHAT: The `{application}` pragma — parsing, expansion, and what it refuses.
//  PIN:  THE REFUSALS ARE THE POINT. A slot that silently fails to expand
//        leaves braces in a sentence that then reaches an embedding, matching
//        nothing anybody would say. Every way that can happen is pinned here.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct UtteranceTemplateTests {

    // MARK: - Reading a slot

    @Test func aDeclaredSlotIsFound() {
        #expect(UtteranceTemplate.slots(in: "Open a new {application} window.")
            == [.application])
        #expect(UtteranceTemplate.hasSlots("Open a new {application} window."))
    }

    @Test func plainProseDeclaresNothing() {
        #expect(UtteranceTemplate.slots(in: "Open a new textedit window.").isEmpty)
        #expect(!UtteranceTemplate.hasSlots("Bring all my windows forward."))
    }

    /// `[W2]` IS NOT A SLOT. A window handle is a runtime reference a person
    /// actually says, and the two syntaxes must never be confused — the whole
    /// reason braces were chosen is that brackets were already taken.
    @Test func aWindowHandleIsNotASlot() {
        #expect(UtteranceTemplate.slots(in: "Bring [W2] to the front.").isEmpty)
        #expect(UtteranceTemplate.unknownPlaceholders(
            in: "Bring [W2] to the front.").isEmpty)
    }

    @Test func aSlotSaidTwiceIsReportedOnce() {
        #expect(UtteranceTemplate.slots(
            in: "Move {application} onto {application}.") == [.application])
    }

    // MARK: - Refusing

    @Test func aMisspelledSlotIsUnknown() {
        #expect(UtteranceTemplate.unknownPlaceholders(
            in: "Open a new {aplication} window.") == ["aplication"])
    }

    @Test func aBraceThatNeverClosesIsUnbalanced() {
        #expect(UtteranceTemplate.unknownPlaceholders(
            in: "Open a new {application window.")
            .contains(UtteranceTemplate.unbalancedMarker))
    }

    @Test func aStrayClosingBraceIsUnbalanced() {
        #expect(UtteranceTemplate.unknownPlaceholders(in: "Open a window}.")
            .contains(UtteranceTemplate.unbalancedMarker))
    }

    @Test func anEmptyBraceIsUnbalanced() {
        #expect(UtteranceTemplate.unknownPlaceholders(in: "Open a new {} window.")
            .contains(UtteranceTemplate.unbalancedMarker))
    }

    /// A brace holding prose rather than a name still leaves braces behind.
    @Test func braceProseIsUnbalanced() {
        #expect(!UtteranceTemplate.unknownPlaceholders(
            in: "Open a new {the app} window.").isEmpty)
    }

    @Test func aDeclaredSlotIsNotUnknown() {
        #expect(UtteranceTemplate.unknownPlaceholders(
            in: "Open a new {application} window.").isEmpty)
    }

    // MARK: - Expanding

    @Test func expandingFillsEveryOccurrence() {
        #expect(UtteranceTemplate.expand(
            "Open a new {application} window.", application: "TextEdit")
            == "Open a new TextEdit window.")
        #expect(UtteranceTemplate.expand(
            "{application} and {application}", application: "Safari")
            == "Safari and Safari")
    }

    /// EXPANSION LEAVES NO BRACES. This is the property every corpus builder
    /// depends on — the negative check the plan calls for, stated once here.
    @Test func expansionLeavesNoBraces() {
        let expanded = UtteranceTemplate.expand(
            "Open a new {application} window.", application: "Pages")
        #expect(!expanded.contains("{"))
        #expect(!expanded.contains("}"))
    }

    @Test func expandingPlainProseChangesNothing() {
        #expect(UtteranceTemplate.expand(
            "Bring all my windows forward.", application: "Safari")
            == "Bring all my windows forward.")
    }
}
