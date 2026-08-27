//
//  AmbientSurfaceRenderTests.swift
//  BonnieAmbientTests
//
//  Pins the tier in the render: the surface leads, it is charged to the
//  budget BEFORE any detail, it never becomes a block or a mention (the
//  `keys` contract describes blocks + mentions only), a stale surface is
//  refused, and one that does not fit is dropped rather than degraded.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientSurfaceRenderTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let pages = AmbientPlace.application("pages")
    private let sketch = AmbientPlace(world: .applications, application: "com.example.sketch")

    private func surface(
        place: AmbientPlace? = nil, name: String = "Pages",
        window: String = "Essay", capturedAt: Date? = nil,
        freshFor: TimeInterval = AmbientSurface.defaultFreshFor
    ) -> AmbientSurface {
        AmbientSurface(
            place: place ?? pages,
            application: .init(name: name, bundleID: "com.apple.iWork.Pages", pid: 7),
            activeWindow: .init(title: window),
            windowCount: 1,
            elements: [.init(identity: "axbutton|share", ordinal: 1, role: "AXButton", kind: "button", label: "Share")],
            capturedAt: capturedAt ?? epoch,
            freshFor: freshFor)
    }

    private func fact(_ content: String) -> AmbientFact {
        AmbientFact(
            world: .applications, application: "pages", slot: .file, content: content,
            subject: "Essay", provenance: .derived, capturedAt: epoch)
    }

    @Test func theSurfaceLeadsAndTheDetailsFollow() {
        let rendering = AmbientRanker.render(
            facts: [fact("Essay — about 900 words.")],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface()],
            at: epoch)
        #expect(rendering.surfaceLines.count == 1)
        #expect(rendering.surfaceLines[0].hasPrefix("On screen: Pages"))
        #expect(rendering.blocks.contains { $0.contains("900 words") })
    }

    @Test func aSurfaceIsNeverABlockOrAMention() {
        let rendering = AmbientRanker.render(
            facts: [fact("Essay — about 900 words.")],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface()],
            at: epoch)
        #expect(!rendering.blocks.contains { $0.contains("On screen:") })
        #expect(!rendering.mentions.contains { $0.contains("On screen:") })
        // The keys contract: blocks + mentions, in order — surfaces have no
        // key and must not inflate it.
        #expect(rendering.keys.count == rendering.blocks.count + rendering.mentions.count)
    }

    /// THE TIERING, AS A DIFFERENTIAL. Same fact, same budget, twice — once
    /// with the surface and once without. The surface's presence is what
    /// starves the detail of its content, which is the foundation spending
    /// first made observable. (The ranker's own standing rule always grants
    /// the first fact a block HEADER regardless of budget, so the content is
    /// what moves, not the block count.)
    @Test func theSurfaceSpendsBeforeTheDetails() {
        let line = surface().surfaceLine(at: epoch)
        let detail = String(repeating: "detail ", count: 200)
        let budget = line.count + 40

        let withSurface = AmbientRanker.render(
            facts: [fact(detail)],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface()],
            budget: budget,
            at: epoch)
        #expect(withSurface.surfaceLines == [line])
        #expect(!withSurface.blocks.contains { $0.contains("detail detail") })

        let withoutSurface = AmbientRanker.render(
            facts: [fact(detail)],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            budget: budget,
            at: epoch)
        #expect(withoutSurface.blocks.contains { $0.contains("detail detail") })
    }

    @Test func aSurfaceTooLargeForTheBudgetIsDroppedNotHalfRendered() {
        let rendering = AmbientRanker.render(
            facts: [],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface()],
            budget: 10,
            at: epoch)
        #expect(rendering.surfaceLines.isEmpty)
    }

    @Test func aStaleSurfaceIsRefused() {
        let rendering = AmbientRanker.render(
            facts: [],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface(freshFor: 10)],
            at: epoch.addingTimeInterval(60))
        #expect(rendering.surfaceLines.isEmpty)
    }

    @Test func callerOrderIsHonoredSoTheLeadLaneLeads() {
        let rendering = AmbientRanker.render(
            facts: [],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            surfaces: [surface(place: sketch, name: "Sketch"), surface()],
            at: epoch)
        #expect(rendering.surfaceLines.count == 2)
        #expect(rendering.surfaceLines[0].contains("Sketch"))
        #expect(rendering.surfaceLines[1].contains("Pages"))
    }

    @Test func noSurfacesRendersExactlyAsBefore() {
        let withNone = AmbientRanker.render(
            facts: [fact("Essay — about 900 words.")],
            utterance: "what am I looking at",
            focusedPlace: .application("pages"),
            at: epoch)
        #expect(withNone.surfaceLines.isEmpty)
        #expect(!withNone.blocks.isEmpty)
        #expect(!withNone.isEmpty)
    }
}
