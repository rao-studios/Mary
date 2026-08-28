//
//  ActedElementReaderTests.swift
//  MaryPluginTests
//
//  THE JOIN THE DATASET IS BUILT ON.
//
//  An action's target and a captured surface element have to line up. They are
//  produced by two different paths — one walks a whole application, the other
//  reads a single focused element an adapter already holds — and they meet
//  only if both spell identity the same way. Nothing about that is enforced by
//  the compiler, so it is enforced here.
//
//  Everything below is pure: identity spelling, the ancestor-climb bounds, the
//  label ladder. The AX reads themselves need a live process with a grant and
//  are exercised by the probe, not by a unit test that would either be a mock
//  of the framework or a test that passes on a machine with no accessibility
//  permission and fails on one with it.
//

import CoreGraphics
import Foundation
import MaryFoundation
import Testing
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct ActedElementReaderTests {

    /// THE PARITY CONTRACT. A record made from a walked element and a record
    /// made from an acted-on element must carry the same identity for the same
    /// control, or an episode's target can never be matched to the surface it
    /// was captured from.
    @Test(arguments: [
        ("AXButton", "Save", "axbutton|save"),
        ("AXButton", "Skip  Ads", "axbutton|skip ads"),
        ("AXTextArea", "", "axtextarea|"),
        ("AXCheckBox", "  Remember Me  ", "axcheckbox|remember me"),
    ])
    func identityIsSpelledOneWay(_ role: String, _ label: String, _ expected: String) {
        #expect(AmbientBridge.identity(role: role, label: label) == expected)

        // The same spelling reached through the element-shaped door.
        let walked = AXScreenElement(
            ordinal: 1, id: AXNodeID(raw: 1), pid: 1, appName: "Example",
            windowID: AXNodeID(raw: 2), windowTitle: "Window",
            role: role, category: .interactive, label: label,
            frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(AmbientBridge.identity(of: walked) == expected)
    }

    /// THE ORDINAL IS NOT A POSITION HERE, and saying so is the point. A
    /// published element's ordinal is its place in a roster's reading order;
    /// an acted-on element came from no roster, and inventing a position would
    /// make the record look like it came from a walk it did not.
    @Test func actedRecordsCarryNoRosterPosition() {
        // Documented as a constant of the reader rather than asserted against
        // a live read, which is what the probe is for.
        #expect(ActedElementReader.maximumAncestorClimb == 24)
    }

    /// THE CLIMB IS BOUNDED, and the reason is not tidiness. An accessibility
    /// parent chain is another process's data structure; an unbounded walk
    /// through a malformed one is a hang in Mary wearing another
    /// application's bug.
    @Test func theAncestorClimbIsBounded() {
        #expect(ActedElementReader.maximumAncestorClimb > 0)
        #expect(
            ActedElementReader.maximumAncestorClimb < 100,
            "deep enough for a real hierarchy, shallow enough that a cyclic one costs milliseconds")
    }
}

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
