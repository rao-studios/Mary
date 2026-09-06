//
//  SpokenRegionTests.swift
//  MaryPluginTests
//
//  WHAT: "The third link in the sidebar" — a place, a kind and a position, over
//        one page.
//  PIN:  THE THREE FILTERS COMPOSE, AND THAT IS THE WHOLE FEATURE. Each of them
//        alone was already there — a kind, an ordinal, a name — and each alone
//        is what a person almost never says. They say where, and what, and
//        which, in one breath, and until they compose the fallback is an ordinal
//        over the whole page, which counts a site's navigation as the first nine
//        things on it.
//        A PLACE THE PAGE DOES NOT HAVE MUST MISS. Widening back to the whole
//        page when a named region is empty is how "the third link in the
//        sidebar" would come to open the third link in the article.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct SpokenRegionTests {

    /// A page with a header, a left column and a body — built as rows, so the
    /// test states the geometry rather than a site.
    static func page() -> [PageRow] {
        var rows: [PageRow] = []
        var ordinal = 0
        func add(_ frame: CGRect, _ label: String, _ kind: PageElementKind) {
            ordinal += 1
            rows.append(PageRow(
                ordinal: ordinal, frame: frame, label: label,
                affordance: kind == .field ? .fill : .press, kind: kind))
        }
        add(CGRect(x: 20, y: 20, width: 120, height: 30), "Home", .link)
        add(CGRect(x: 200, y: 20, width: 300, height: 30), "Search this site", .field)
        add(CGRect(x: 10, y: 200, width: 120, height: 20), "Contents", .link)
        add(CGRect(x: 10, y: 240, width: 120, height: 20), "History", .link)
        add(CGRect(x: 10, y: 280, width: 120, height: 20), "References", .link)
        for index in 0..<8 {
            add(
                CGRect(x: 320, y: 150 + index * 50, width: 520, height: 30),
                "Body link \(index + 1)", .link)
        }
        return PageRegionDerivation.assign(
            rows: rows, pageFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    @Test func aPositionCountsInsideTheRegionThatWasNamed() throws {
        let rows = Self.page()
        // Sanity: the fixture really does have three places.
        #expect(Set(rows.compactMap(\.region)) == [.header, .leading, .main])

        let outcome = SpokenReference.resolve(
            phrase: "the third link in the sidebar", among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(outcome)"); return
        }
        #expect(rows[index].label == "References")
    }

    /// THE SAME WORDS, A DIFFERENT PLACE, A DIFFERENT ANSWER.
    @Test func theSamePositionInAnotherRegionReachesAnotherRow() throws {
        let rows = Self.page()
        let outcome = SpokenReference.resolve(
            phrase: "the third link in the article", among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(outcome)"); return
        }
        #expect(rows[index].label == "Body link 3")
    }

    /// A NAME SAID ABOUT A PLACE IS STILL A NAME.
    ///
    /// PIN: THE REGION'S WORDS COME OUT OF THE NEEDLE WITH THE KIND'S. A phrase
    /// still carrying "in the sidebar" matches no label anywhere, so this would
    /// fall through every rung and refuse.
    @Test func aNameInsideARegionStillReachesItsRow() throws {
        let rows = Self.page()
        let outcome = SpokenReference.resolve(
            phrase: "the History link in the sidebar", among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(outcome)"); return
        }
        #expect(rows[index].label == "History")
    }

    /// A KIND ALONE, INSIDE A PLACE, WHEN THE PLACE HOLDS ONE OF THEM.
    @Test func aKindAloneInsideARegionResolvesWhenItIsTheOnlyOne() throws {
        let rows = Self.page()
        let outcome = SpokenReference.resolve(
            phrase: "the search box at the top", among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(outcome)"); return
        }
        #expect(rows[index].label == "Search this site")
    }

    /// A PLACE THE PAGE DOES NOT HAVE IS A MISS, NOT A WIDENING.
    @Test func aRegionThePageHasNoneOfRefuses() {
        let rows = Self.page()
        let reached = SpokenReference.reached(
            phrase: "the second link at the bottom of the page", among: rows)
        #expect(reached == nil)
    }

    /// AND A REGION IT HAS THAT HOLDS NONE OF THE KIND IS TOO.
    @Test func aRegionHoldingNoneOfTheNamedKindRefuses() {
        let rows = Self.page()
        let reached = SpokenReference.reached(
            phrase: "the second field in the sidebar", among: rows)
        #expect(reached == nil)
    }

    /// WITHOUT A REGION NAMED, NOTHING CHANGES. The whole page counts, exactly
    /// as it did before regions existed.
    @Test func aPhraseNamingNoPlaceCountsTheWholePage() throws {
        let rows = Self.page()
        let outcome = SpokenReference.resolve(phrase: "the second link", among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(outcome)"); return
        }
        #expect(rows[index].label == "Contents")
    }
}
