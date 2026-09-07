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

    /// The fixture really does have three places.
    @Test func theFixtureHasThreePlaces() {
        #expect(Set(Self.page().compactMap(\.region)) == [.header, .leading, .main])
    }

    /// A phrase over the page, and the row it must reach — or nil, when the
    /// place it names must refuse.
    struct Spoken: CustomTestStringConvertible {
        let claim: String
        let phrase: String
        let reaches: String?
        var testDescription: String { claim }
    }

    /// THE SAME WORDS, A DIFFERENT PLACE, A DIFFERENT ANSWER. A name said about
    /// a place is still a name — PIN: THE REGION'S WORDS COME OUT OF THE NEEDLE
    /// WITH THE KIND'S; a phrase still carrying "in the sidebar" matches no label
    /// anywhere and would fall through every rung. A kind alone, inside a place
    /// that holds one of them, resolves. A PLACE THE PAGE DOES NOT HAVE IS A
    /// MISS, NOT A WIDENING — and so is a place it has that holds none of the
    /// kind. WITHOUT A REGION NAMED, NOTHING CHANGES: the whole page counts,
    /// exactly as it did before regions existed.
    static let spoken: [Spoken] = [
        Spoken(claim: "a position counts inside the region named",
               phrase: "the third link in the sidebar", reaches: "References"),
        Spoken(claim: "the same position in another region",
               phrase: "the third link in the article", reaches: "Body link 3"),
        Spoken(claim: "a name inside a region",
               phrase: "the History link in the sidebar", reaches: "History"),
        Spoken(claim: "a kind alone inside a region holding one",
               phrase: "the search box at the top", reaches: "Search this site"),
        Spoken(claim: "a region the page has none of",
               phrase: "the second link at the bottom of the page", reaches: nil),
        Spoken(claim: "a region holding none of the named kind",
               phrase: "the second field in the sidebar", reaches: nil),
        Spoken(claim: "no place named counts the whole page",
               phrase: "the second link", reaches: "Contents"),
    ]

    @Test(arguments: spoken) func aPlaceAKindAndAPosition(_ spoken: Spoken) {
        let rows = Self.page()
        guard let label = spoken.reaches else {
            #expect(
                SpokenReference.reached(phrase: spoken.phrase, among: rows) == nil,
                "\(spoken.claim)")
            return
        }
        let outcome = SpokenReference.resolve(phrase: spoken.phrase, among: rows)
        guard case .one(let index) = outcome else {
            Issue.record("\(spoken.claim): \(outcome)")
            return
        }
        #expect(rows[index].label == label, "\(spoken.claim)")
    }
}
