//
//  AmbientSurfaceStoreTests.swift
//  MaryAmbientTests
//
//  WHAT: Tier-0 store — latest-wins by capture time, drop-at-expiry, lane isolation.
//  OUT:  AmbientContextStore surface box + surfaceLine
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientSurfaceStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let pages = AmbientPlace.application("pages")
    private let sketch = AmbientPlace(world: .applications, application: "com.example.sketch")

    private func surface(
        place: AmbientPlace? = nil,
        name: String = "Pages",
        window: String? = "Kohinoor Essay",
        windowCount: Int = 1,
        minimized: Int = 0,
        elements: [AmbientSurface.Element] = [],
        focused: AmbientSurface.Element? = nil,
        pageNotYetRead: Bool = false,
        capturedAt: Date? = nil,
        freshFor: TimeInterval = AmbientSurface.defaultFreshFor
    ) -> AmbientSurface {
        AmbientSurface(
            place: place ?? pages,
            application: .init(name: name, bundleID: "com.apple.iWork.Pages", pid: 42),
            activeWindow: window.map { AmbientSurface.Window(title: $0) },
            windowCount: windowCount,
            minimizedCount: minimized,
            elements: elements,
            focused: focused,
            pageNotYetRead: pageNotYetRead,
            capturedAt: capturedAt ?? epoch,
            freshFor: freshFor)
    }

    private func element(
        _ ordinal: Int, label: String, kind: String = "button"
    ) -> AmbientSurface.Element {
        AmbientSurface.Element(
            identity: "axbutton|" + label.lowercased(),
            ordinal: ordinal, role: "AXButton", kind: kind, label: label)
    }

    // MARK: - The box

    @Test func latestCaptureWinsRegardlessOfArrivalOrder() {
        let store = AmbientContextStore()
        let newer = surface(window: "Newer", capturedAt: epoch.addingTimeInterval(10))
        let older = surface(window: "Older", capturedAt: epoch)
        store.noteSurface(newer, at: epoch.addingTimeInterval(11))
        store.noteSurface(older, at: epoch.addingTimeInterval(12))
        #expect(store.surface(place: pages, at: epoch.addingTimeInterval(13))?
            .activeWindow?.title == "Newer")
    }

    @Test func newerCaptureReplacesTheHeldOne() {
        let store = AmbientContextStore()
        store.noteSurface(surface(window: "First"), at: epoch)
        let second = surface(window: "Second", capturedAt: epoch.addingTimeInterval(5))
        store.noteSurface(second, at: epoch.addingTimeInterval(5))
        #expect(store.surface(place: pages, at: epoch.addingTimeInterval(6))?
            .activeWindow?.title == "Second")
    }

    @Test func expiredSurfacesDropRatherThanDegrade() {
        let store = AmbientContextStore()
        store.noteSurface(surface(freshFor: 10), at: epoch)
        #expect(store.surface(place: pages, at: epoch.addingTimeInterval(5)) != nil)
        #expect(store.surface(place: pages, at: epoch.addingTimeInterval(11)) == nil)
        #expect(store.surfaces(at: epoch.addingTimeInterval(11)).isEmpty)
    }

    @Test func aStaleHolderNeverBlocksAFreshArrival() {
        let store = AmbientContextStore()
        store.noteSurface(
            surface(window: "Stale", capturedAt: epoch.addingTimeInterval(100)),
            at: epoch.addingTimeInterval(100))
        // Much later, an honest new capture with an EARLIER date than
        // nothing — the stale holder is pruned, not consulted.
        let fresh = surface(window: "Fresh", capturedAt: epoch.addingTimeInterval(500))
        store.noteSurface(fresh, at: epoch.addingTimeInterval(500))
        #expect(store.surface(place: pages, at: epoch.addingTimeInterval(501))?
            .activeWindow?.title == "Fresh")
    }

    @Test func lanesHoldIndependently() {
        let store = AmbientContextStore()
        store.noteSurface(surface(), at: epoch)
        store.noteSurface(surface(place: sketch, name: "Sketch"), at: epoch)
        #expect(store.surfaces(at: epoch.addingTimeInterval(1)).count == 2)
        store.forgetSurface(place: pages)
        let remaining = store.surfaces(at: epoch.addingTimeInterval(1))
        #expect(remaining.count == 1)
        #expect(remaining.first?.application.name == "Sketch")
    }

    @Test func clearDropsSurfacesToo() {
        let store = AmbientContextStore()
        store.noteSurface(surface(), at: epoch)
        store.clear()
        #expect(store.surfaces(at: epoch.addingTimeInterval(1)).isEmpty)
    }

    // MARK: - The line

    @Test func surfaceLineCarriesWindowFocusOfferingAndAge() {
        let sample = surface(
            windowCount: 2,
            elements: [
                element(1, label: "Share"), element(2, label: "Add Page"),
                element(3, label: "Zoom"),
            ],
            focused: AmbientSurface.Element(
                identity: "axtextarea|",
                ordinal: 9, role: "AXTextArea", kind: "text area", label: ""))
        let line = sample.surfaceLine(at: epoch.addingTimeInterval(8))
        #expect(line == "On screen: Pages — \"Kohinoor Essay\" "
            + "(front of 2 windows; focused: text area) "
            + "— offering: Share, Add Page, Zoom — seen 8s ago")
    }

    @Test func offeringNamesAtMostTheNotableLimit() {
        let sample = surface(
            elements: (1...12).map { element($0, label: "Item \($0)") })
        let line = sample.surfaceLine(at: epoch)
        #expect(line.contains("Item \(AmbientSurface.notableLimit)"))
        #expect(!line.contains("Item \(AmbientSurface.notableLimit + 1),"))
        #expect(line.contains("+\(12 - AmbientSurface.notableLimit) more"))
    }

    @Test func focusedElementLeadsTheOffering() {
        let sample = surface(
            elements: [element(1, label: "First"), element(2, label: "Chosen")],
            focused: element(2, label: "Chosen"))
        let line = sample.surfaceLine(at: epoch)
        #expect(line.contains("offering: Chosen, First"))
    }

    @Test func windowlessSurfaceStillSpeaks() {
        let line = surface(window: nil).surfaceLine(at: epoch)
        #expect(line.hasPrefix("On screen: Pages"))
        #expect(!line.contains("\"\""))
    }

    @Test func pageNotYetReadIsSaidNeverImplied() {
        let line = surface(pageNotYetRead: true).surfaceLine(at: epoch)
        #expect(line.contains("page not yet read"))
    }

    @Test func lineRespectsTheCap() {
        let sample = surface(
            window: String(repeating: "w", count: 300),
            elements: (1...30).map {
                element($0, label: String(repeating: "x", count: 100))
            })
        let line = sample.surfaceLine(at: epoch)
        #expect(line.count <= AmbientSurface.surfaceLineCap)
        #expect(line.hasSuffix("…"))
    }
}
