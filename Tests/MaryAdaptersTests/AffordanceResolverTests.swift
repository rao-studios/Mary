//
//  AffordanceResolverTests.swift
//  BonniePluginTests
//
//  THE TWO QUESTIONS, kept apart.
//
//  `PageElementResolver` answers "which thing did they NAME" and every case
//  it already answers must keep answering identically — that is what the
//  first rung of this ladder buys, and the regression tests below are what
//  prove it. The new rung answers "which thing would DO what they asked",
//  and only ever runs when the first one came back empty.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryAdapters

@Suite struct AffordanceResolverTests {

    /// Nothing under test dereferences the handle; both resolvers are pure
    /// functions of the value fields. `PageElementTests`' seam.
    private static let handle = AXUIElementCreateSystemWide()

    private func element(
        _ ordinal: Int,
        _ kind: PageElementKind,
        _ label: String,
        role: String = "AXButton",
        enabled: Bool = true
    ) -> PageElement {
        PageElement(
            ordinal: ordinal,
            role: role,
            kind: kind,
            label: label,
            frame: CGRect(x: 0, y: CGFloat(ordinal) * 60, width: 120, height: 40),
            isEnabled: enabled,
            axElement: Self.handle)
    }

    /// A fresh store per case: the resolver ranks against a published slate,
    /// and a shared one would carry another test's page.
    private func resolved(
        _ goal: String, _ elements: [PageElement]
    ) -> PageElementResolution {
        let store = AmbientElementIndexStore()
        let scope = AmbientElementScope.affordances(in: .native(.applications))
        AffordanceResolver.publish(elements, scope: scope, store: store)
        return AffordanceResolver.resolve(
            goal: goal, in: elements, scope: scope, store: store)
    }

    // MARK: - The incident

    @Test func aGoalReachesTheControlThatServesIt() {
        let page = [
            element(1, .button, "Skip Ads"),
            element(2, .button, "Subscribe"),
            element(3, .link, "Watch later", role: "AXLink"),
        ]
        // WHERE THE LEXICAL LADDER ACTUALLY STOPS, measured rather than
        // assumed. The bare phrase resolves: `stripped` drops "the", and
        // "skip ads" contains "skip ad". Spoken as a person speaks it, it
        // does not — the needle carries "can you", and containment fails both
        // directions while the all-words rung drops "ad" for being two
        // characters. That second shape is the one a voice produces, and it
        // is what the meaning rung is for.
        #expect(PageElementResolver.resolve(phrase: "skip the ad", in: page)
            != .none)
        #expect(PageElementResolver.resolve(
            phrase: "can you skip the ad", in: page) == .none)
        guard case .one(let element) = resolved("can you skip the ad", page) else {
            Issue.record("expected one resolution"); return
        }
        #expect(element.label == "Skip Ads")
    }

    @Test func fullScreenReachesThePlayersOwnControl() {
        let page = [
            element(1, .button, "Play (k)"),
            element(2, .button, "Full screen (f)"),
            element(3, .button, "Settings"),
        ]
        guard case .one(let element) = resolved("make it full screen", page) else {
            Issue.record("expected one resolution"); return
        }
        #expect(element.label == "Full screen (f)")
    }

    // MARK: - The refusals

    @Test func twoServingControlsRefuseByName() {
        let page = [
            element(1, .button, "Skip Ads"),
            element(2, .button, "Skip Intro"),
        ]
        guard case .ambiguous(let rivals) = resolved("skip that", page) else {
            Issue.record("expected an ambiguity"); return
        }
        #expect(Set(rivals.map(\.label)) == ["Skip Ads", "Skip Intro"])
        // And the sentence names them, rather than asking to be more specific.
        let refusal = PageElementResolver.ambiguityRefusal(
            rivals, phrase: "skip that")
        #expect(refusal.contains("Skip Ads"))
        #expect(refusal.contains("Skip Intro"))
    }

    @Test func aPageOfferingNothingRelevantResolvesNothing() {
        let page = [
            element(1, .button, "Subscribe"),
            element(2, .button, "Share"),
        ]
        #expect(resolved("skip the ad", page) == .none)
    }

    @Test func theMeaningRungNeverOffersADisabledControl() {
        // A phrase the naming ladder cannot reach — "skip intro" is not
        // contained in "Skip Ads Now" either direction, and the all-words rung
        // fails on "intro" — so only the meaning rung can answer, and it must
        // decline: `requires: .pressable` is unsatisfiable for a disabled
        // control by construction, because `AffordanceRule` strips its
        // capabilities.
        let page = [element(1, .button, "Skip Ads Now", enabled: false)]
        #expect(PageElementResolver.resolve(phrase: "skip the intro", in: page)
            == .none)
        #expect(resolved("skip the intro", page) == .none)
    }

    @Test func aDisabledControlTheNamingLadderFINDSStillReachesTheHands() {
        // Deliberately NOT filtered here. `perform` refuses it with "\"X\" is
        // there but not available right now" — a far more useful sentence
        // than "I can't find that", and the reason this resolver does not
        // quietly drop what the page plainly shows.
        let page = [element(1, .button, "Skip Ads", enabled: false)]
        guard case .one = resolved("skip the ad", page) else {
            Issue.record("expected the naming ladder to find it"); return
        }
    }

    @Test func aSharedStopWordCannotCarryAMatch() {
        let page = [element(1, .button, "The Defiance Act")]
        #expect(resolved("can you skip the ad", page) == .none)
    }

    // MARK: - The naming ladder is untouched

    @Test func anOrdinalStillResolvesExactlyAsBefore() {
        let page = [
            element(1, .video, "First video", role: "AXLink"),
            element(2, .video, "Second video", role: "AXLink"),
            element(3, .video, "Third video", role: "AXLink"),
        ]
        guard case .one(let element) = resolved("play the third video", page) else {
            Issue.record("expected one resolution"); return
        }
        #expect(element.label == "Third video")
    }

    @Test func aNamedTitleStillResolvesExactlyAsBefore() {
        let page = [
            element(1, .video, "Swift in 100 Seconds", role: "AXLink"),
            element(2, .video, "Rust in 100 Seconds", role: "AXLink"),
        ]
        guard case .one(let element) =
            resolved("play Swift in 100 Seconds", page) else {
            Issue.record("expected one resolution"); return
        }
        #expect(element.label == "Swift in 100 Seconds")
    }

    @Test func identityIsRoleAndLabelRatherThanPosition() {
        // A page re-flows between the read and the press; the ordinal moves
        // and the identity does not. `relocate` re-finds by this.
        let before = element(3, .button, "Skip Ads")
        let after = element(9, .button, "Skip Ads")
        #expect(AffordanceResolver.identity(of: before)
                == AffordanceResolver.identity(of: after))
    }
}
