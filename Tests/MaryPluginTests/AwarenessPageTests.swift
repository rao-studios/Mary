//
//  AwarenessPageTests.swift
//  MaryPluginTests
//
//  WHAT: A page as the work in front of someone — the brief, the navigation,
//        and the follow-up that means "of the answers we were just looking at".
//  PIN:  THE NAVIGATION CASE IS THE LOAD-BEARING ONE. Mary retracts her own
//        navigations inside the engine; nobody was watching for the PERSON
//        clicking a link, so a slate of offers from the page they left stayed
//        live for its whole ninety seconds.
//

import CoreGraphics
import os
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryComputerUse
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct AwarenessPageTests {

    // MARK: - Fixtures

    private static func registration(
        page: Bool = true
    ) -> AwarenessRegistration {
        AwarenessRegistration(
            applicationID: "test-browser",
            bundleIdentifiers: ["com.example.browser"],
            displayName: "Test Browser",
            surface: page ? .page : .document(corpus: nil),
            hasCodeSurface: false,
            hasProseSurface: false)
    }

    private static func shell(
        title: String?, url: String?
    ) -> WebSurfaceAX.Reading {
        WebSurfaceAX.Reading(
            title: title, url: url,
            pageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 700))
    }

    private static func roster(_ labels: [String]) -> PageRoster {
        let elements = labels.enumerated().map { index, label in
            AXScreenElement(
                ordinal: index + 1,
                id: AXNodeID(raw: UInt(index + 1)),
                pid: 1, appName: "Test Browser",
                windowID: AXNodeID(raw: 1), windowTitle: "results",
                role: "AXLink", subrole: nil, category: .interactive,
                label: label,
                frame: CGRect(x: 0, y: index * 30, width: 400, height: 24),
                isEnabled: true, isFocused: false,
                containerTrail: [], provenance: .seen)
        }
        return PageRoster(
            elements: elements, map: PageMapSummary(),
            pageFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    // MARK: - The brief

    /// WHAT THEY ARE LOOKING AT, and what it is offering — with an age on it,
    /// because offers from a read that happened five minutes ago describe a
    /// page that may well have moved.
    @Test func theBriefNamesThePageAndItsOffersWithAnAge() {
        let brief = AwarenessBrief.page(
            shell: Self.shell(title: "fred again - YouTube", url: "https://youtube.com/results"),
            roster: Self.roster(["Boiler Room: London", "Rooftop Live"]),
            age: 12,
            browser: "Test Browser")
        #expect(brief.contains("fred again - YouTube"))
        #expect(brief.contains("youtube"))
        #expect(brief.contains("12 seconds ago"))
        #expect(brief.contains("Boiler Room"))
    }

    /// A PAGE NOBODY HAS READ SAYS SO, and names the verb that would read it —
    /// more useful than silence, more honest than a guess.
    @Test func anUnreadPageSaysSoAndNamesTheVerbs() {
        let brief = AwarenessBrief.page(
            shell: Self.shell(title: "An Article", url: "https://example.com/piece"),
            roster: nil, age: nil, browser: "Test Browser")
        #expect(brief.contains("have not read this page"))
        #expect(brief.contains("read_page_text"))
    }

    // MARK: - The navigation

    /// THEY WENT SOMEWHERE THEMSELVES. The offers from the page they left are
    /// dropped, and the ledger is told this is real work in the browser — which
    /// is what keeps a page in the conversation once another window comes
    /// forward.
    @Test func aHandNavigationRetractsAndStampsWork() async {
        let pages = [
            AwarenessPageSite(
                registration: Self.registration(),
                shell: Self.shell(title: "Results", url: "https://example.com/a"),
                roster: Self.roster(["One", "Two"]), rosterAge: 3),
            AwarenessPageSite(
                registration: Self.registration(),
                shell: Self.shell(title: "An Article", url: "https://example.com/b"),
                roster: Self.roster(["One", "Two"]), rosterAge: 8),
        ]
        let index = OSAllocatedUnfairLock<Int>(initialState: 0)
        let stamped = OSAllocatedUnfairLock<[AmbientPlace]>(initialState: [])
        let observer = AwarenessPageObserver(
            support: {
                let support = AwarenessSupport()
                support.reconcile([Self.registration()])
                return support
            }(),
            site: { _ in
                let current = index.withLock { value -> Int in
                    defer { value = min(value + 1, pages.count - 1) }
                    return value
                }
                return pages[current]
            },
            onNavigation: { place, _ in
                stamped.withLock { $0.append(place) }
            })

        await observer.pollOnce()
        #expect(stamped.withLock { $0 }.isEmpty, "the first sighting is not a navigation")
        let first = observer.snapshot()
        #expect(first.offers == 2, "the read that stands describes this page")

        await observer.pollOnce()
        #expect(
            stamped.withLock { $0 } == [AmbientPlaceResolver.browserPlace],
            "the page changed under us — that is the person browsing")
        let second = observer.snapshot()
        #expect(second.offers == 0, "offers from the page they left describe nothing here")
        #expect(second.lastNavigation != nil)
        let brief = try? #require(observer.promptContribution())
        #expect(brief?.contains("have not read this page") == true)
    }

    /// A BROWSER THAT DID NOT ASK TO BE FOLLOWED IS NOT FOLLOWED. Saying
    /// nothing is the right answer rather than watching it anyway.
    @Test func aBrowserWithoutTheEdgeIsNotFollowed() async {
        let support = AwarenessSupport()
        support.reconcile([Self.registration(page: false)])
        let observer = AwarenessPageObserver(
            support: support,
            site: { _ in
                AwarenessPageSite(
                    registration: Self.registration(),
                    shell: Self.shell(title: "Anything", url: "https://example.com"))
            },
            onNavigation: { _, _ in })
        await observer.pollOnce()
        #expect(observer.promptContribution() == nil)
        #expect(observer.observedPlace == nil)
    }

    // MARK: - What the page says

    /// THE HALF OF A PAGE THE ACTING LISTING THROWS AWAY. A question about an
    /// article needs its words, and duplicates collapse — the reader emits some
    /// elements twice, which is harmless in a numbered listing and absurd in a
    /// passage.
    @Test func thePageTextReadsInOrderAndCollapsesDuplicates() {
        let passage = PageListing.text(
            Self.roster(["A Headline", "A Headline", "Some body text", "More text"]),
            pageName: "An Article")
        #expect(passage.contains("An Article"))
        let headlines = passage.components(separatedBy: "A Headline").count - 1
        #expect(headlines == 1, "said once, not twice")
        #expect(passage.contains("Some body text"))
        #expect(
            passage.range(of: "Some body text")!.lowerBound
                < passage.range(of: "More text")!.lowerBound,
            "reading order is the roster's own order")
    }

    // MARK: - The follow-up

    /// "OPEN THE SECOND ONE" AFTER A SEARCH MEANS THE SECOND ANSWER.
    ///
    /// A phrase that names nothing but a position can only mean the list they
    /// were just looking at; a phrase that names something is a name, and a name
    /// is looked for across the whole page.
    @Test(arguments: [
        ("open the second one", true),
        ("the first video", true),
        ("the last one", true),
        ("play the third", true),
        ("click the Boiler Room link", false),
        ("press accept all", false),
        ("the search box", false),
    ])
    func onlyAPositionalPhraseScopesToTheResults(_ phrase: String, _ expected: Bool) {
        #expect(
            PageElementKindDerivation.namesOnlyAPosition(phrase) == expected,
            "[\(phrase)]")
    }
}
