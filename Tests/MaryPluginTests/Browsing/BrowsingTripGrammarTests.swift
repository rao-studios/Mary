//
//  BrowsingTripGrammarTests.swift
//  MaryPluginTests
//
//  WHAT: The trip grammar refuses what it exists to refuse, and every shipped
//        trip is one a runner can take.
//  OUT:  BrowsingTrip, BrowsingTripValidator
//  PIN:  THE VALIDATOR IS THE SITE-AGNOSTICITY RULE, AND A RULE THAT CANNOT FAIL
//        IS A COMMENT. Each test below plants exactly the shortcut somebody will
//        reach for — a URL in an expectation, a host name, a page's own words
//        asserted as a class, a fact nobody derives — and requires the validator
//        to name it. Then the whole shipped corpus is walked through the same
//        gate, so a trip added later cannot quietly hard-code a route.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BrowsingTripGrammarTests {

    static var tripsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Trips", isDirectory: true)
    }

    static func trip(_ legs: [TripLeg]) -> BrowsingTrip {
        BrowsingTrip(
            id: "a-trip", category: "act", summary: "A fixture.",
            stage: TripStage(), legs: legs)
    }

    // MARK: - What it refuses

    /// AN ADDRESS IN AN EXPECTATION IS A HARD-CODED ROUTE. The lane speaks site
    /// names and holds URLs; a fixture must not be the one place one survives.
    @Test func anAddressInAnExpectationIsRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "open it", provider: TripProviderExpectation(
                applicationID: "https://example.com")),
        ]))
        #expect(issues.contains { $0.problem.contains("address") })
    }

    /// AND SO IS A BARE HOST, which is the same mistake without the scheme.
    @Test func aHostNameInAnExpectationIsRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "open it", page: TripPageExpectation(
                winner: TripRowClass(kind: "youtube.com"))),
        ]))
        #expect(issues.contains { $0.problem.contains("host name") })
    }

    /// THE PERSON'S OWN WORDS ARE EXEMPT. A trip whose utterance names a site is
    /// an ordinary trip — that is what somebody says out loud.
    @Test func theUtteranceMayNameASite() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(
                say: "find me a fireplace video on youtube.com",
                routing: TripRoutingExpectation(
                    skill: "search_web", intent: "operate",
                    arguments: ["query": "a fireplace video on youtube"])),
        ]))
        #expect(issues.isEmpty, "\(issues)")
    }

    /// A PAGE'S OWN WORDS ASSERTED AS A CLASS. There is no label field by
    /// construction, so the shortcut takes the shape of a sentence in some other
    /// free-text field — and length is what gives it away.
    @Test func aPhraseWhereAClassBelongsIsRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "press it", page: TripPageExpectation(
                winner: TripRowClass(
                    kind: "Alpine touring boots reviewed — the ten best of this year"))),
        ]))
        #expect(issues.contains { $0.problem.contains("is a phrase, not a class") })
    }

    /// A FACT NOBODY DERIVES IS A TYPO THAT WOULD OTHERWISE PASS SILENTLY.
    @Test func aFactTheSealDoesNotDecideIsRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "press it", page: TripPageExpectation(
                winner: TripRowClass(facts: ["looksImportant"]))),
        ]))
        #expect(issues.contains { $0.problem.contains("not a RowFact") })
    }

    /// EVERY FACT THE SEAL DOES DECIDE IS ASSERTABLE, and turns into the real
    /// option set — the list in the validator and the members of `RowFacts` are
    /// two halves of one thing and drift apart silently otherwise.
    @Test func everyKnownFactNamesARealMember() {
        for name in BrowsingTripValidator.knownFacts {
            #expect(
                BrowsingTripValidator.facts(named: [name]) != [],
                "\(name) is listed as known and maps to no RowFact")
        }
        #expect(BrowsingTripValidator.facts(named: ["inOverlay", "promoted"])
            == [.inOverlay, .promoted])
    }

    /// A ROUTE DOES ONE THING OR THE OTHER. A leg expecting both a winner and a
    /// refusal describes an outcome that cannot happen.
    @Test func aWinnerAndARefusalTogetherAreRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "press it", page: TripPageExpectation(
                winner: TripRowClass(affordance: .press), refusal: .elementNotFound)),
        ]))
        #expect(issues.contains { $0.problem.contains("one or the other") })
    }

    /// AN INTENT MARY DOES NOT READ, and a naming rung that is not one.
    @Test func vocabularyOutsideMarysOwnIsRefused() {
        let intent = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "x", routing: TripRoutingExpectation(skill: "read_page", intent: "browse")),
        ]))
        #expect(intent.contains { $0.problem.contains("not an intent") })

        let basis = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "x", page: TripPageExpectation(
                winner: TripRowClass(lexicalBasis: "vibes"))),
        ]))
        #expect(basis.contains { $0.problem.contains("not a rung") })
    }

    /// AN ORDINAL COUNTS FROM ONE, the way a listing speaks it.
    @Test func anOrdinalBelowOneIsRefused() {
        let issues = BrowsingTripValidator.validate(Self.trip([
            TripLeg(say: "x", page: TripPageExpectation(
                winner: TripRowClass(ordinalWithinKind: 0))),
        ]))
        #expect(issues.contains { $0.problem.contains("counts from one") })
    }

    /// A CATEGORY OUTSIDE THE EIGHT, and a trip with nothing in it.
    @Test func theShapeOfATripIsChecked() {
        var trip = Self.trip([])
        trip.category = "browsing"
        let issues = BrowsingTripValidator.validate(trip)
        #expect(issues.contains { $0.path == "category" })
        #expect(issues.contains { $0.path == "legs" })
    }

    // MARK: - Round tripping

    /// A TRIP IS DATA, so what comes back out of a file is what went in.
    @Test func aTripRoundTrips() throws {
        let trip = BrowsingTrip(
            id: "round-trip", category: "search",
            summary: "A fixture.",
            stage: TripStage(pageClass: .resultsPage, front: "browser"),
            legs: [
                TripLeg(
                    say: "open the second one",
                    routing: TripRoutingExpectation(
                        skill: "click_on_page", intent: "operate", lane: .confidence,
                        shape: .singleString),
                    page: TripPageExpectation(
                        verb: .openResult,
                        winner: TripRowClass(
                            facts: ["inResultGroup"], factsAbsent: ["echoOfQuery"],
                            affordance: .press, ordinalWithinKind: 2)),
                    engine: TripEngineExpectation(
                        receipt: .navigation, landed: true, budgetMs: 3500)),
            ],
            navigates: true)

        let again = try BrowsingTrip.decode(trip.encoded())
        #expect(again == trip)
    }

    // MARK: - The shipped corpus

    /// EVERY TRIP IN THE REPOSITORY PASSES THE GATE. This is the test that keeps
    /// the rule alive as trips are added — including by whoever is mid-round and
    /// in a hurry.
    @Test func everyShippedTripValidates() {
        let trips = BrowsingTrip.all(under: Self.tripsRoot)
        #expect(!trips.isEmpty, "no trips found under \(Self.tripsRoot.path)")
        for (url, trip) in trips {
            let issues = BrowsingTripValidator.validate(trip)
            #expect(
                issues.isEmpty,
                "\(url.lastPathComponent): \(issues.map(\.description).joined(separator: "; "))")
        }
    }

    /// AND EVERY TRIP IS FILED WHERE ITS CATEGORY SAYS, so a round can run one
    /// category by naming a directory.
    @Test func everyTripIsFiledUnderItsCategory() {
        for (url, trip) in BrowsingTrip.all(under: Self.tripsRoot) {
            let directory = url.deletingLastPathComponent().lastPathComponent
            #expect(directory == trip.category, "\(url.lastPathComponent) sits in \(directory)")
            #expect(
                url.lastPathComponent == "\(trip.id).trip.json",
                "\(url.lastPathComponent) is not named for its id")
        }
    }

    /// A PENDING LEG IS COUNTED, NOT FAILED. A corpus authored ahead of the
    /// engine has to distinguish "not built yet" from "built and wrong", and the
    /// runners read exactly this.
    @Test func aPendingLegIsHeldBackFromTheLiveSet() {
        let trip = Self.trip([
            TripLeg(say: "one"),
            TripLeg(say: "two", pending: "round 3"),
            TripLeg(say: "three"),
        ])
        #expect(trip.liveLegs.map(\.index) == [0, 2])
        #expect(trip.liveLegs.map(\.leg.say) == ["one", "three"])
    }

    /// AND THE SHIPPED CORPUS HAS BOTH KINDS. A corpus with nothing pending was
    /// authored to the engine that exists rather than to the experience wanted;
    /// a corpus that is all pending measures nothing today.
    @Test func theCorpusHoldsWorkToDoAndWorkToMeasure() {
        let trips = BrowsingTrip.all(under: Self.tripsRoot).map(\.trip)
        let legs = trips.flatMap(\.legs)
        #expect(legs.contains { $0.pending != nil }, "nothing is waiting on a round")
        #expect(legs.contains { $0.pending == nil }, "nothing can be measured today")
        // Every category the plan names is represented.
        #expect(Set(trips.map(\.category)) == BrowsingTrip.categories)
    }

    /// NOTHING IN THE CORPUS IS UNREADABLE, AND A WALK SAYS SO OUT LOUD.
    ///
    /// PIN: THE FAILURE THIS TEST EXISTS FOR ALREADY HAPPENED. Every trip
    /// omitting one optional field failed to decode, `compactMap(try?)` dropped
    /// it, and four of eight categories left the corpus while every suite over
    /// it stayed green — a corpus that silently shrinks always passes.
    @Test func everyFileThatLooksLikeATripIsOneWeCanRead() {
        let corpus = BrowsingTrip.corpus(under: Self.tripsRoot)
        let named = corpus.unreadable
            .map { "\($0.url.lastPathComponent): \($0.problem)" }
            .joined(separator: "; ")
        #expect(corpus.unreadable.isEmpty, "\(named)")
        #expect(!corpus.trips.isEmpty)
    }

    /// AND A BROKEN ONE IS REPORTED RATHER THAN SKIPPED — the rule must be able
    /// to fail, or it is the same silence with more words.
    @Test func aTripThatWillNotDecodeIsNamed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-trip-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"id": "broken"}"#.utf8)
            .write(to: directory.appendingPathComponent("broken.trip.json"))
        try Self.trip([TripLeg(say: "fine")]).encoded()
            .write(to: directory.appendingPathComponent("fine.trip.json"))

        let corpus = BrowsingTrip.corpus(under: directory)
        #expect(corpus.trips.count == 1)
        #expect(corpus.unreadable.count == 1)
        #expect(corpus.unreadable.first?.url.lastPathComponent == "broken.trip.json")
    }

    /// A HAND-AUTHORED TRIP MAY LEAVE THE QUIET FIELDS OUT. `navigates` and the
    /// stage's optional conditions default rather than throwing — the whole
    /// reason the corpus vanished once already.
    @Test func theQuietFieldsMayBeOmitted() throws {
        let json = #"""
        {"id": "terse", "category": "read", "summary": "A fixture.",
         "legs": [{"say": "what is this page about"}]}
        """#
        let trip = try BrowsingTrip.decode(Data(json.utf8))
        #expect(trip.navigates == false)
        #expect(trip.stage.pageClass == .any)
        #expect(trip.stage.front == "browser")
        #expect(BrowsingTripValidator.validate(trip).isEmpty)
    }

    /// SEEDS AND PHRASES LIVE OUTSIDE THE REPOSITORY, and the advice says where.
    @Test func stagingPointsAtTheMachineRatherThanTheRepository() {
        #expect(TripStaging.seedsURL.path.contains(".mary/trips"))
        #expect(!TripStaging.seedsURL.path.contains("Fixtures"))
        #expect(TripStaging.missingSeedAdvice(for: .watchPage).contains("watchPage"))
        #expect(TripStaging.missingPhraseAdvice(for: "namedRow").contains("namedRow"))
        // `any` and `blank` need no address at all.
        #expect(TripStaging.seed(for: .any) == nil)
        #expect(TripStaging.seed(for: .blank) == nil)
    }

    /// A KEYED LEG SAYS SO. The legs that must name something on a page are the
    /// ones whose words come from the machine, and they are exactly the ones a
    /// runner cannot stage on its own.
    @Test func everyKeyedLegAlsoCarriesAReadableDefault() {
        for (url, trip) in BrowsingTrip.all(under: Self.tripsRoot) {
            for leg in trip.legs where leg.sayKey != nil {
                #expect(
                    !leg.say.isEmpty,
                    "\(url.lastPathComponent): a keyed leg still reads as a journey")
            }
        }
    }
}
