//
//  SkillOutcomeTargetTests.swift
//  MaryPluginTests
//
//  WHAT: The outcome's target and adapter trail — the geometry half of the
//        behavioural record.
//  OUT:  SkillOutcome / BehavioralAction
//  PIN:  Split from ActedElementReaderTests when the reader moved to
//        MaryComputerUse; the outcome contract stays with the adapter layer.
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryPlugin

/// The outcome's two new fields — the geometry half of the behavioural record.
@Suite struct SkillOutcomeTargetTests {

    static let frame = AXFrame(
        space: .axGlobalTopLeft,
        rect: .init(x: 10, y: 20, width: 100, height: 30),
        center: .init(x: 60, y: 35),
        capturedAt: Date(timeIntervalSince1970: 1_787_821_200))

    static var record: AXElementRecord {
        AXElementRecord(
            identity: "axtextarea|", ordinal: 0, role: "AXTextArea",
            label: "", kind: "text area", appName: "TextEdit", pid: 4321,
            windowTitle: "Essay", frame: frame)
    }

    /// NIL IS THE HONEST DEFAULT. A skill that only thinks, or answers from
    /// held context, acted on nothing — and a record claiming otherwise would
    /// put a fabricated target in the dataset.
    @Test func anOutcomeCarriesNoTargetUnlessOneIsGiven() {
        let outcome = SkillOutcome(ok: true, summary: "Thought about it.")
        #expect(outcome.target == nil)
        #expect(outcome.adapterTrail.isEmpty)
    }

    @Test func anActedOutcomeCarriesWhatItTouched() {
        let outcome = SkillOutcome(
            ok: true, summary: "Typed 27 characters into Essay.",
            target: Self.record, adapterTrail: ["typer"])
        #expect(outcome.target?.identity == "axtextarea|")
        #expect(outcome.target?.frame.rect.width == 100)
        #expect(outcome.adapterTrail.map(\.rawValue) == ["typer"])
    }

    /// THE TRAIL IS ORDERED, PRIMARY FIRST. A prose write that landed by
    /// keystroke names the prose surface and then the typer, and "how did she
    /// actually do that" is answerable from the record rather than from a log.
    @Test func theAdapterTrailKeepsItsOrder() {
        let outcome = SkillOutcome(
            ok: true, summary: "Replaced the opening paragraph.",
            target: Self.record, adapterTrail: ["prose-surface", "typer"])
        #expect(outcome.adapterTrail.map(\.rawValue) == ["prose-surface", "typer"])
    }

    /// The outcome's target is exactly the codec's target type, so composing
    /// a behavioural action needs no conversion — which is the whole reason
    /// the record type lives down in the schema layer.
    @Test func theOutcomeTargetIsTheCodecTarget() {
        let outcome = SkillOutcome(
            ok: true, summary: "Typed.", target: Self.record, adapterTrail: ["typer"])
        let action = BehavioralAction(
            intention: "type_at_cursor",
            skill: AbilitySkillReference(
                packageID: "writing", packageVersion: "1.0.0",
                abilityID: "writing", abilityTitle: "Writing", abilityTint: "#000",
                skillID: "writing.type-at-cursor", skillTitle: "Type at cursor",
                invocationName: "type_at_cursor"),
            target: outcome.target,
            adapters: outcome.adapterTrail)
        #expect(action.target == Self.record)
        #expect(action.adapters == outcome.adapterTrail)
    }
}
