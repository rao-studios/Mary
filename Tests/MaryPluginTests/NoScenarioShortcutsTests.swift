//
//  NoScenarioShortcutsTests.swift
//  MaryPluginTests
//
//  WHAT: The browsing lane holds no words belonging to a page, a trip or a
//        recording — and every page it recorded is a page it argues with.
//  OUT:  Source scan of the browsing lane; the trip corpus; the page fixtures
//  PIN:  THE CYCLE'S ONE STANDING TEMPTATION. Driving the engine from real
//        journeys means somebody eventually has a failing leg, a recorded page in
//        front of them, and a two-minute fix: name the row. That fix passes the
//        trip, passes review if nobody looks closely, and generalizes to nothing
//        — the next page defeats it and the lane has grown a rule per site per
//        widget forever, which is exactly what the whole design exists to
//        prevent. `NoSiteShortcutsTests` forbids three shortcuts INTO a page;
//        this forbids the shortcut into a FIXTURE, which is the one this working
//        method invites.
//        A CONSTANT WITH NO PAGE BEHIND IT IS A PREFERENCE. The floors and
//        weights are described as measured against recorded pages; a page that
//        is recorded and never argued with measures nothing, so every fixture in
//        the repository has to appear in the calibration suite.
//        IT SCANS SOURCE, NOT BEHAVIOUR, for the same reason its neighbour does:
//        the rule is not a sentence in a document, it is this test.
//

import Foundation
import XCTest
@testable import MaryPlugin

final class NoScenarioShortcutsTests: XCTestCase {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// THE LANE, WHEREVER IT LIVES. The engine moves from `WebSurface/` to
    /// `Browsing/` during the swap, and a guard that scanned one path would go
    /// quiet on the day the code moved — which is the day it is most needed.
    static var laneDirectories: [URL] {
        ["Sources/MaryPlugin/WebSurface", "Sources/MaryPlugin/Browsing"]
            .map { repositoryRoot.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func laneFiles() throws -> [(path: String, body: String)] {
        var found: [(path: String, body: String)] = []
        for directory in laneDirectories {
            guard let walk = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for url in walk.compactMap({ $0 as? URL }) where url.pathExtension == "swift" {
                // THE TRIP MACHINERY IS NOT THE LANE. It exists to hold this
                // vocabulary — the fact names, the refusal names, the page
                // classes — and scanning it would forbid the grammar itself.
                guard !url.path.contains("/Trips/") else { continue }
                found.append((
                    url.lastPathComponent,
                    try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return found
    }

    /// Every quoted string literal in a source file, folded.
    ///
    /// PIN: ONE SCANNER OVER THE RAW SOURCE, BECAUSE STRIPPING COMMENTS FIRST
    /// BREAKS THE STRINGS. The first version of this cut each line at its first
    /// `//` and then paired quotes — and this lane is full of `"https://"`, so
    /// the strip cut those literals in half, left an odd quote behind, and every
    /// literal after it in the file was read INVERTED: the code between the
    /// strings was collected as though it were the strings. It reported nothing
    /// and passed a planted violation, which is the exact failure a guard exists
    /// not to have. Comments and strings have to be tracked in the same pass, in
    /// the order they occur, and multi-line and raw strings are what make that
    /// more than an afternoon's regular expression.
    static func literals(in source: String) -> [String] {
        var found: [String] = []
        let characters = Array(source)
        var index = 0

        func matches(_ token: [Character], at start: Int) -> Bool {
            guard start + token.count <= characters.count else { return false }
            return Array(characters[start..<(start + token.count)]) == token
        }

        while index < characters.count {
            // A LINE COMMENT RUNS TO THE NEWLINE, and the PINs in this lane
            // quote the pages they were measured against on purpose.
            if matches(["/", "/"], at: index) {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if matches(["/", "*"], at: index) {
                index += 2
                while index < characters.count, !matches(["*", "/"], at: index) { index += 1 }
                index = min(index + 2, characters.count)
                continue
            }
            // A RAW STRING SUSPENDS ESCAPING, so `#"…"#` is scanned by its own
            // delimiters or a backslash inside it would end it early.
            if matches(["#", "\""], at: index) {
                index += 2
                var literal = ""
                while index < characters.count, !matches(["\"", "#"], at: index) {
                    literal.append(characters[index])
                    index += 1
                }
                index = min(index + 2, characters.count)
                found.append(literal)
                continue
            }
            // A MULTI-LINE STRING, whose opening delimiter is three quotes and
            // would otherwise read as one string plus one stray quote.
            if matches(["\"", "\"", "\""], at: index) {
                index += 3
                var literal = ""
                while index < characters.count, !matches(["\"", "\"", "\""], at: index) {
                    if characters[index] == "\\" { index += 2; continue }
                    literal.append(characters[index])
                    index += 1
                }
                index = min(index + 3, characters.count)
                found.append(literal)
                continue
            }
            if characters[index] == "\"" {
                index += 1
                var literal = ""
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\" { index += 2; continue }
                    literal.append(characters[index])
                    index += 1
                }
                index = min(index + 1, characters.count)
                found.append(literal)
                continue
            }
            index += 1
        }
        return found.map { RowFactsDerivation.folded($0) }.filter { !$0.isEmpty }
    }

    // MARK: - The words a page owns

    /// A ROW'S OWN WORDS MUST NOT BE IN THE ENGINE. Every label in every recorded
    /// page, folded, checked against every string literal the lane holds.
    func testTheLaneHoldsNoWordsFromARecordedPage() throws {
        let root = Self.repositoryRoot
            .appendingPathComponent("Tests/MaryPluginTests/Fixtures/PageRoutes")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var labels: Set<String> = []
        let maskedAddress = RowFactsDerivation.folded(PageRosterFixture.maskedAddress)
        for url in urls where url.pathExtension == "json" {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let fixture = try? JSONDecoder().decode(PageRosterFixture.self, from: data)
            else { continue }
            for row in fixture.rows {
                let folded = RowFactsDerivation.folded(row.label)
                // A ONE-WORD LABEL IS ORDINARY VOCABULARY. "Search", "Videos" and
                // "Next" belong to the language as much as to any page, and a
                // rule that forbade them would forbid the lane describing itself.
                guard folded.split(separator: " ").count >= 3 else { continue }
                // AND THE MASK IS NOT A PAGE'S WORDS. Every address a recording
                // holds was replaced by `PageRosterFixture.maskedAddress`, so the
                // mask matches its own output and the rule reported the file that
                // defines it. Excluded by identity rather than by shortening the
                // rule, which would let a real three-word label through.
                guard folded != maskedAddress else { continue }
                labels.insert(folded)
            }
        }
        XCTAssertFalse(labels.isEmpty, "no recorded pages to check against")

        var offences: [String] = []
        for file in try Self.laneFiles() {
            for literal in Self.literals(in: file.body) where labels.contains(literal) {
                offences.append("\(file.path) holds a recorded page's own words: \"\(literal)\"")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            \(offences.joined(separator: "\n"))

            A row's words belong to one page. Reach it by a FACT the seal decides \
            about it — see RowFacts — or by a rule about the shape of pages. A \
            condition on what this page said is a rule that the next page defeats.
            """)
    }

    /// AND NO TRIP'S UTTERANCE EITHER. A leg that only passes because the engine
    /// recognizes the sentence is measuring nothing at all.
    func testTheLaneHoldsNoTripUtterance() throws {
        let trips = BrowsingTrip.corpus(under: Self.repositoryRoot
            .appendingPathComponent("Tests/MaryPluginTests/Fixtures/Trips"))
        XCTAssertTrue(
            trips.unreadable.isEmpty,
            "\(trips.unreadable.map(\.url.lastPathComponent))")
        var utterances: Set<String> = []
        for (_, trip) in trips.trips {
            for leg in trip.legs {
                let folded = RowFactsDerivation.folded(leg.say)
                guard folded.split(separator: " ").count >= 3 else { continue }
                utterances.insert(folded)
            }
        }
        XCTAssertFalse(utterances.isEmpty, "no trips to check against")

        var offences: [String] = []
        for file in try Self.laneFiles() {
            for literal in Self.literals(in: file.body) where utterances.contains(literal) {
                offences.append("\(file.path) holds a trip's own utterance")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            \(offences.joined(separator: "\n"))

            A leg that passes because the engine recognizes its sentence measures \
            nothing. What the words should reach is a matter for the packages — a \
            route fixture, a spoken value, a summary that names its surface.
            """)
    }

    // MARK: - A constant with a page behind it

    /// EVERY RECORDED PAGE IS ARGUED WITH. The floors and weights are cited as
    /// measured against real pages; a page recorded and never replayed measures
    /// nothing, and a constant nothing measures is one somebody will round off.
    func testEveryRecordedPageIsRepliedToByTheCalibrationSuite() throws {
        let root = Self.repositoryRoot
            .appendingPathComponent("Tests/MaryPluginTests/Fixtures/PageRoutes")
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertFalse(names.isEmpty, "no recorded pages")

        let suites = ["PageRouteCalibrationTests.swift", "PageRouteFixtureTests.swift"]
            .map { Self.repositoryRoot.appendingPathComponent("Tests/MaryPluginTests/\($0)") }
        let argued = try suites
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(argued.isEmpty, "the calibration suites are not where this expects")

        let unargued = names.filter { !argued.contains($0) }
        XCTAssertTrue(
            unargued.isEmpty,
            """
            \(unargued.joined(separator: ", ")) recorded and never argued with.

            A page in the repository that no suite replays measures nothing, and \
            every floor and weight in PageRouter is described as measured against \
            these pages. Add it to PageRouteCalibrationTests, or delete it.
            """)
    }

    /// THE RULE MUST BE ABLE TO FAIL — all three of them, on the shapes they
    /// forbid rather than on a string that merely looks like one.
    func testTheRulesWouldCatchWhatTheyForbid() {
        let planted = #"if row.label == "Alpine touring boots reviewed" { return true }"#
        XCTAssertTrue(Self.literals(in: planted).contains("alpine touring boots reviewed"))

        // A COMMENT IS NOT CODE. The PINs in this lane quote the pages they were
        // measured against on purpose, and forbidding that would cost the
        // reasoning that makes the rules readable.
        let commented = #"// measured against "Alpine touring boots reviewed""#
        XCTAssertTrue(Self.literals(in: commented).isEmpty)

        // AND AN ADDRESS DOES NOT INVERT THE SCANNER. `"https://"` holds the
        // token a line comment starts with; cutting the line there halved the
        // literal and read every string after it in the file inside out — the
        // measured bug this scanner was rewritten for.
        let address = """
        let scheme = "https://"
        if row.label == "Alpine touring boots reviewed" { return true }
        """
        let afterAnAddress = Self.literals(in: address)
        XCTAssertTrue(
            afterAnAddress.contains("alpine touring boots reviewed"),
            "a literal after an address was missed — \(afterAnAddress)")

        // A MULTI-LINE STRING IS ONE LITERAL, not one plus a stray quote.
        let multiline = "let prompt = \"\"\"\nAlpine touring boots reviewed\n\"\"\"\n"
            + "let after = \"Boiler Room London\"\n"
        let both = Self.literals(in: multiline)
        XCTAssertTrue(both.contains("alpine touring boots reviewed"))
        XCTAssertTrue(both.contains("boiler room london"), "\(both)")

        // AND A SHORT LABEL IS ORDINARY VOCABULARY, not a page's property.
        XCTAssertEqual(RowFactsDerivation.folded("Search").split(separator: " ").count, 1)
    }
}
