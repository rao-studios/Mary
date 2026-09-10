//
//  AffordanceResolverTests.swift
//  MaryPluginTests
//
//  WHAT: Named element vs affordance rung — name first, meaning only when empty.
//  OUT:  PageElementResolver + AffordanceResolver
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryPlugin

@Suite struct AffordanceResolverTests {

    /// Nothing under test dereferences the handle; both resolvers are pure
    /// functions of the value fields.
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
        let scope = AmbientElementScope.affordances(in: .lane(.applications))
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

    // MARK: - The refusals

    // MARK: - The naming ladder is untouched

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

}
