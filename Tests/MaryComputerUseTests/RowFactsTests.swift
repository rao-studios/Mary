//
//  RowFactsTests.swift
//  MaryComputerUseTests
//
//  WHAT: What is true of a row, decided once from the reading alone.
//  OUT:  RowFactsDerivation
//  PIN:  THESE WERE SEVEN ORDERED `if`s INSIDE A ROUTING GATE, each deriving a
//        property of a row from its label at ranking time. Every threshold below
//        came off a live page and is moved here whole, so this suite is where a
//        change to one of them has to argue with a measurement.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct RowFactsTests {

    private func row(
        _ ordinal: Int,
        _ label: String,
        affordance: SeenAffordance = .press,
        group: PageGroupRef? = nil,
        hints: [String] = []
    ) -> PageRow {
        PageRow(
            ordinal: ordinal,
            frame: CGRect(x: 0, y: CGFloat(ordinal) * 40, width: 400, height: 30),
            label: label,
            labelSource: .textInside,
            affordance: affordance,
            group: group,
            hints: hints)
    }

    private func facts(
        _ rows: [PageRow], groups: [PageGroup] = []
    ) -> [RowFacts] {
        RowFactsDerivation.derive(rows: rows, groups: groups).map(\.facts)
    }

    /// A SITE'S OWN TABS, DRAWN AS ONE ROW — long, named, pressable and first, so
    /// every ranking that reached past the map opened it. What gives it away is
    /// that it is a LIST: three or more segments of a word or two.
    @Test func aStripOfShortNamesIsFurniture() {
        let derived = facts([
            row(1, "News + AI Chat & Images · Videos · Web"),
            // A REAL TITLE CARRYING A SEPARATOR IS NOT ONE: two segments, one long.
            row(2, "Boiler Room London · 1:02:33"),
        ])
        #expect(derived[0].contains(.separatedStrip))
        #expect(!derived[1].contains(.separatedStrip))
    }

    /// An address a card printed above its link is not a title.
    @Test func aBareAddressIsNotATitle() {
        let derived = facts([row(1, "https://example.com/watch"), row(2, "Ski touring")])
        #expect(derived[0].contains(.bareAddress))
        #expect(!derived[1].contains(.bareAddress))
    }

    /// The page asking, rather than the page answering.
    @Test func aCallToActionSaysSo() {
        let derived = facts([row(1, "Sign in"), row(2, "Alpine touring boots reviewed")])
        #expect(derived[0].contains(.callToAction))
        #expect(!derived[1].contains(.callToAction))
    }

    /// Shorter than anything anybody searched for.
    @Test func aShortLabelIsTooShortForATitle() {
        let derived = facts([row(1, "Next"), row(2, "Alpine touring boots reviewed")])
        #expect(derived[0].contains(.tooShortForTitle))
        #expect(!derived[1].contains(.tooShortForTitle))
    }

    /// What a page calls a row it was paid to show — a HINT, never folded into
    /// the label, which is why it can be ranked on at all.
    @Test func aPromotionHintIsCarried() {
        let derived = facts([
            row(1, "Alpine touring boots reviewed", hints: ["Sponsored"]),
            row(2, "Alpine touring boots reviewed", hints: ["12:04"]),
        ])
        #expect(derived[0].contains(.promoted))
        #expect(!derived[1].contains(.promoted))
    }

    /// A BAND OF MOSTLY-SHORT LABELS IS A STRIP, by shape rather than by name.
    @Test func aBandOfShortLabelsIsFurniture() {
        let band = PageGroupRef(id: 1, kind: .band)
        let rows = [
            row(1, "News", group: band),
            row(2, "Videos", group: band),
            row(3, "Web", group: band),
        ]
        let derived = facts(rows, groups: [
            PageGroup(id: 1, kind: .band, memberOrdinals: [1, 2, 3]),
        ])
        #expect(derived.allSatisfy { $0.contains(.inFurnitureBand) })
    }

    /// …AND A BAND OF REAL TITLES IS NOT. The same shape test, the other answer.
    @Test func aBandOfTitlesIsNotFurniture() {
        let band = PageGroupRef(id: 1, kind: .band)
        let rows = [
            row(1, "Alpine touring boots reviewed", group: band),
            row(2, "Ski touring in the Alps this winter", group: band),
            row(3, "The best boots of the season, tested", group: band),
        ]
        let derived = facts(rows, groups: [
            PageGroup(id: 1, kind: .band, memberOrdinals: [1, 2, 3]),
        ])
        #expect(derived.allSatisfy { !$0.contains(.inFurnitureBand) })
    }

    /// NOTHING BEHIND A DIALOG CAN BE REACHED WHILE IT IS THERE, and every row
    /// knows which side of it it is on without anyone re-deriving membership.
    @Test func anOverlaySplitsThePageInTwo() {
        let overlay = PageGroupRef(id: 9, kind: .overlay)
        let rows = [
            row(1, "Accept all", group: overlay),
            row(2, "Alpine touring boots reviewed"),
        ]
        let derived = facts(rows, groups: [
            PageGroup(id: 9, kind: .overlay, memberOrdinals: [1]),
        ])
        #expect(derived[0].contains(.inOverlay))
        #expect(!derived[0].contains(.behindOverlay))
        #expect(derived[1].contains(.behindOverlay))
    }

    /// WITH NO DIALOG UP, NOTHING IS BEHIND ONE. The absent case is a fact too:
    /// a whole page marked `behindOverlay` would demote every row it has.
    @Test func withNoOverlayNothingIsBehindOne() {
        let derived = facts([row(1, "Alpine touring boots reviewed")])
        #expect(!derived[0].contains(.behindOverlay))
        #expect(!derived[0].contains(.inOverlay))
    }

    /// Group kinds carry through as facts rather than as strings to re-match.
    @Test func groupKindsBecomeFacts() {
        let rows = [
            row(1, "Alpine touring boots reviewed",
                group: PageGroupRef(id: 1, kind: .card)),
            row(2, "Reload", group: PageGroupRef(id: 2, kind: .toolbar)),
            row(3, "Email address", group: PageGroupRef(id: 3, kind: .form)),
        ]
        let derived = facts(rows)
        #expect(derived[0].contains(.inResultGroup))
        #expect(derived[1].contains(.inToolbar))
        #expect(derived[2].contains(.inForm))
        #expect(!derived[1].isDisjoint(with: .furnitureGroups))
        #expect(derived[0].isDisjoint(with: .furnitureGroups))
    }

    /// A LABEL TWO ROWS CLAIM IS A LABEL NEITHER OWNS. Measured as pervasive:
    /// an outer link and the text inside it are both emitted, so 15 of 80 rows
    /// on one real page shared a name with another row on the same read.
    @Test func aDuplicatedLabelIsMarkedOnBothRows() {
        let derived = facts([
            row(1, "Ski touring"),
            row(2, "ski  TOURING"),   // the same words, however they are cased
            row(3, "Alpine touring boots reviewed"),
        ])
        #expect(derived[0].contains(.duplicateLabel))
        #expect(derived[1].contains(.duplicateLabel))
        #expect(!derived[2].contains(.duplicateLabel))
    }

    // MARK: - The query's own echo

    /// A RESULTS PAGE SHOWS YOU WHAT YOU ASKED FOR, in its own search box and
    /// again under "Searches related to …". Both are pressable, well named and
    /// the right length, so nothing but the query can tell them from an answer.
    @Test func theQuerySaidBackIsAnEcho() {
        let query = "alpine touring boots"
        #expect(RowFactsDerivation.isEcho("alpine touring boots", of: query))
        // A recognized magnifier or a trailing mark is still the echo.
        #expect(RowFactsDerivation.isEcho("alpine touring boots ⌕", of: query))
        // A REAL TITLE CONTAINS THE QUERY AND THEN SAYS SOMETHING.
        #expect(!RowFactsDerivation.isEcho("Alpine touring boots REVIEWED", of: query))
    }

    /// AND A PAGE TRUNCATES ITS OWN ECHO — "Searches related to a fred again
    /// video on" drops the last word and is still the page talking about the
    /// search rather than answering it.
    @Test func aTruncatedEchoIsStillAnEcho() {
        #expect(RowFactsDerivation.isEcho(
            "Searches related to a fred again video on",
            of: "a fred again video on youtube"))
    }

    /// AN EMPTY QUERY ECHOES NOTHING. The no-pick case asks with "", and a rule
    /// that answered true there would refuse every row on the page.
    @Test func anEmptyQueryEchoesNothing() {
        #expect(!RowFactsDerivation.isEcho("Alpine touring boots", of: ""))
    }
}
