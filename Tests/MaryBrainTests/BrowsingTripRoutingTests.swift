//
//  BrowsingTripRoutingTests.swift
//  MaryBrainTests
//
//  WHAT: Every trip leg's words, measured against the shipped corpus — which
//        skill they reach, on which lane, with which arguments filled.
//  IN:   Tests/MaryPluginTests/Fixtures/Trips/**/*.trip.json
//  OUT:  the R1 half of a round's scoreboard
//  PIN:  THE REAL ARBITRATOR, THE REAL PACKAGES, THE REAL EMBEDDING MODEL.
//        `mutingTheVideoDispatchesWithNoModelRound` proved one sentence this
//        way and found two faults the design had not predicted; this is that
//        test generalized to the whole corpus, so every journey a person takes
//        is measured rather than the two somebody remembered to write down.
//        CALIBRATION-GATED, LIKE ITS PARENT. It needs NLEmbedding and the
//        installed packages, so it abstains on a machine without them rather
//        than asserting against a fake vectorizer — a routing threshold measured
//        against a fake is a number about nothing.
//        REPORTED IN FULL, ASSERTED IN PART. Every leg prints its line whether it
//        passes or not, because a near miss (0.71 against 0.70) is the finding
//        that says which fixture to write, and a bare pass/fail hides it.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct BrowsingTripRoutingTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    /// The corpus lives with the plugin tests, beside the recordings it explains.
    static var tripsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MaryPluginTests/Fixtures/Trips", isDirectory: true)
    }

    /// The production snapshot, loaded once and shared — see
    /// `BrowsingRehearsalSnapshot` for why a hand-built one measured nothing.
    private static func snapshot() throws -> AbilityRuntime.Snapshot? {
        BrowsingRehearsalSnapshot.load()
    }

    /// WHAT THE STAGE SUPPLIES, ASKED OF THE GRAPH RATHER THAN LISTED HERE.
    ///
    /// PIN: A TEST THAT SPELLS OUT "A BROWSER MEANS web-page" IS THE HARD-CODING
    /// THE CORPUS REFUSES, one layer up. The classes come from the registered
    /// profile of whatever the stage says is in front, which is the same place a
    /// turn gets them.
    static func targetClasses(
        front: String, in snapshot: AbilityRuntime.Snapshot
    ) -> Set<String> {
        BrowsingRehearsalSnapshot.targetClasses(front: front, in: snapshot)
    }

    /// One leg, measured.
    struct Measured {
        var trip: String
        var index: Int
        var say: String
        var wanted: TripRoutingExpectation
        var intent: String
        var offered: [String]
        var winner: AbilityRuntimeSkill?
        var shape: EmbeddingRouting.ConfidenceArgumentShape?
        var arguments: [String: String]
        var top: [(String, Float)]

        var line: String {
            let top = top.prefix(3)
                .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
                .joined(separator: ", ")
            return String(
                format: "  %-34@ %-46@ intent=%-8@ offered=%2d -> %-20@ shape=%-20@ %@",
                "\(trip)[\(index)]" as NSString,
                (say.count > 44 ? String(say.prefix(44)) + "…" : say) as NSString,
                intent as NSString,
                offered.count,
                (winner?.reference.invocationName ?? "none") as NSString,
                (shape.map { "\($0)" } ?? "nil") as NSString,
                top as NSString)
        }
    }

    static func measure(
        trip: BrowsingTrip, index: Int, leg: TripLeg,
        wanted: TripRoutingExpectation, snapshot: AbilityRuntime.Snapshot,
        store: RoutingHabitStore
    ) -> Measured {
        let classes = targetClasses(front: trip.stage.front, in: snapshot)
        let arbitration = AbilityRosterRehearsal.arbitration(
            snapshot: snapshot, utterance: leg.say,
            targetClasses: classes, habits: store)
        let offered = arbitration.trace.selected.map(\.reference.invocationName)
        let verdict = TurnTriage.verdict(
            query: leg.say, registry: snapshot,
            offeredNames: Set(offered), habits: store)
        let winner = verdict.uniqueSkill
        let shape = winner.flatMap {
            EmbeddingRouting.confidenceShape(of: $0, utterance: leg.say)
        }
        var arguments: [String: String] = [:]
        if let winner, shape != nil {
            let filled = EmbeddingRouting.filledArguments(
                for: winner, utterance: leg.say, applicationID: nil,
                applicationProfiles: snapshot.plugins.applicationProfiles)
            if let data = filled.json.data(using: .utf8),
               let table = try? JSONSerialization.jsonObject(with: data)
                as? [String: String] {
                arguments = table
            }
        }
        let top = verdict.skillAffinities
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { (snapshot.skill(id: $0.key)?.reference.invocationName
                ?? $0.key.rawValue, $0.value) }
        return Measured(
            trip: trip.id, index: index, say: leg.say, wanted: wanted,
            intent: verdict.intent?.rawValue ?? "nil",
            offered: offered.sorted(), winner: winner, shape: shape,
            arguments: arguments, top: Array(top))
    }

    // MARK: - The corpus, measured

    /// EVERY LEG THAT STATES WHERE ITS WORDS SHOULD GO, MEASURED THROUGH THE
    /// GATES A TURN RUNS. What fails here is an `R1` finding, and the report
    /// beside it says which fixture would fix it.
    @Test func everyLegsWordsReachTheSkillItNames() throws {
        guard let snapshot = try Self.snapshot() else { return }
        let store = RoutingHabitStore()
        let corpus = BrowsingTrip.corpus(under: Self.tripsRoot)
        #expect(corpus.unreadable.isEmpty, "\(corpus.unreadable.map(\.url.lastPathComponent))")
        #expect(!corpus.trips.isEmpty, "no trips under \(Self.tripsRoot.path)")

        var report: [String] = []
        var wrong: [String] = []

        for (_, trip) in corpus.trips {
            for (index, leg) in trip.legs.enumerated() {
                guard leg.pending == nil, let wanted = leg.routing else { continue }
                // A LEG WHOSE SKILL IS NOT SHIPPED YET IS NOT A ROUTING FAULT.
                guard snapshot.reference(forInvocation: wanted.skill) != nil else { continue }
                let measured = Self.measure(
                    trip: trip, index: index, leg: leg, wanted: wanted,
                    snapshot: snapshot, store: store)
                report.append(measured.line)

                let name = "\(trip.id)[\(index)]"
                if let intent = wanted.intent, measured.intent != intent {
                    wrong.append("\(name) read as \(measured.intent), not \(intent)")
                }
                if let reached = measured.winner?.reference.invocationName,
                   reached != wanted.skill {
                    wrong.append("\(name) reached \(reached), not \(wanted.skill)")
                }
                if wanted.lane == .confidence {
                    if measured.winner == nil {
                        wrong.append("\(name) had no unique winner, so \(wanted.skill) costs a model round")
                    } else if measured.shape == nil {
                        wrong.append("\(name) has no fillable shape, so it costs a model round")
                    }
                }
                if let shape = wanted.shape, let found = measured.shape,
                   "\(found)" != shape.rawValue {
                    wrong.append("\(name) shape \(found), not \(shape.rawValue)")
                }
                for (key, value) in wanted.arguments ?? [:] {
                    guard measured.shape != nil else { continue }
                    guard let filled = measured.arguments[key] else {
                        wrong.append("\(name) did not fill \(key)")
                        continue
                    }
                    guard RowFactsDerivation.folded(filled)
                        == RowFactsDerivation.folded(value) else {
                        wrong.append("\(name) filled \(key) as \"\(filled)\", not \"\(value)\"")
                        continue
                    }
                }
            }
        }
        print(report.joined(separator: "\n"))

        // THE BASELINE IS A LEDGER, NOT A PASS. Round 0 measured thirteen places
        // where a browsing sentence does not reach the skill it names, and each
        // is work a later round owes. A suite that simply failed would be noise
        // nobody reads; a suite that simply passed would lose them. So the set
        // of findings is compared with the recorded one BOTH WAYS: a new one is
        // a regression, and a fixed one has to be struck off here deliberately.
        let found = Set(wrong)
        let regressions = found.subtracting(Self.knownFindings).sorted()
        let fixed = Self.knownFindings.subtracting(found).sorted()
        let newly = "\(regressions.count) NEW routing finding(s):\n"
            + regressions.joined(separator: "\n")
        #expect(regressions.isEmpty, "\(newly)")
        let gone = "\(fixed.count) finding(s) no longer reproduce — strike them from "
            + "knownFindings and say which round did it:\n"
            + fixed.joined(separator: "\n")
        #expect(fixed.isEmpty, "\(gone)")
    }

    /// WHAT ROUND 0 MEASURED, AND WHICH ROUND OWES THE ANSWER.
    ///
    /// PIN: EVERY LINE HERE IS A SENTENCE A PERSON WOULD SAY THAT DOES NOT REACH
    /// THE SKILL THAT ANSWERS IT. They are recorded rather than fixed here
    /// because the fix for each is package data or a generic gate — a route
    /// fixture naming its surface, a summary that says which surface it is
    /// about, an intent the classifier reads wrongly — and doing them one at a
    /// time with a measurement beside each is the whole method. Moving a floor
    /// to make one go away is not admitted (see `EmbeddingCalibrationTests`).
    ///
    /// Grouped by what is actually wrong:
    ///
    /// AN ACTION READ AS SOMETHING ELSE. The confidence lane only runs on an
    /// action turn, so a plain instruction read as `converse` or `perceive`
    /// costs a model round — and a model round with "video" or "the web" in the
    /// sentence is where the reported wrong web search came from.
    ///
    /// A TWIN THAT HAS NOT BEEN SEPARATED. `control-playback` and
    /// `control-media` were separated by naming their surfaces in their
    /// summaries; the DESCRIBE twins (`now_playing` and `describe_media`) and
    /// the LISTING twins (`list_app_windows`, `list_playlists` and `list_tabs`)
    /// have the same collision and have not been.
    ///
    /// A BROWSER QUESTION ANSWERED BY ANOTHER SURFACE. "Which tab am I on"
    /// reaching a playlist skill is the plainest version of it.
    ///
    /// A PAGE SKILL OFFERED WITH AN EDITOR IN FRONT. `read_page_text` wins
    /// "what does this function do" though nothing on the stage is a web page —
    /// invariant 5, and the reason the context trips exist.
    ///
    /// (A VERB THE CORPUS DOES NOT CARRY was listed here once — "open a new tab"
    /// reaching no unique winner — and it was the instrument: measured on an
    /// empty stage. With web-page on the stage it wins outright.)
    static let knownFindings: Set<String> = [
        // An action read as something else.
        "ambiguous-name[0] read as perceive, not operate",
        "fill-and-submit[0] read as converse, not operate",
        "press-by-ordinal-within-kind[0] read as converse, not operate",
        "transport-round-trip[1] read as converse, not operate",
        "page-question-from-an-editor[1] read as perceive, not ask",
        // …and the model round each one therefore costs.
        "press-by-ordinal-within-kind[0] had no unique winner, so click_on_page costs a model round",
        "transport-round-trip[1] had no unique winner, so control_media costs a model round",
        // STRUCK, AND NOT BY A ROUND: "new-tab[0] had no unique winner" was the
        // instrument, not the corpus. It was measured on an empty stage — the
        // hand-built snapshot held no application profiles, so no target class
        // stood — and with web-page on the stage new_tab wins outright. The
        // other twelve reproduce identically on the real stage. See
        // BrowsingRehearsalSnapshot.
        // Twins that have not been separated.
        "describe-media[0] reached now_playing, not describe_media",
        "list-tabs[0] reached list_app_windows, not list_tabs",
        // A browser question answered by another surface.
        "which-tab[0] reached list_playlists, not current_page",
        // A page skill offered with an editor in front.
        "page-question-from-an-editor[1] reached read_page_text, not read_enclosing_unit",
        // The peeling leaves the phrase that named the surface in the query.
        "search-then-open-second[0] filled query as \"alpine touring boots on the web\", not \"alpine touring boots\"",
    ]

    /// A QUESTION MUST NEVER BECOME A SEARCH. The reported defect's own shape,
    /// asked of every leg that is a question: the model reaching for `search_web`
    /// with a page in front is how "what is this about" opened a results page.
    @Test func noQuestionInTheCorpusReachesASearch() throws {
        guard let snapshot = try Self.snapshot() else { return }
        let store = RoutingHabitStore()
        var wrong: [String] = []
        var report: [String] = []

        for (_, trip) in BrowsingTrip.corpus(under: Self.tripsRoot).trips {
            for (index, leg) in trip.legs.enumerated() {
                guard leg.pending == nil, leg.routing?.intent == "ask" else { continue }
                let classes = Self.targetClasses(front: trip.stage.front, in: snapshot)
                let arbitration = AbilityRosterRehearsal.arbitration(
                    snapshot: snapshot, utterance: leg.say,
                    targetClasses: classes, habits: store)
                let offered = Set(arbitration.trace.selected.map(\.reference.invocationName))
                let verdict = TurnTriage.verdict(
                    query: leg.say, registry: snapshot, offeredNames: offered, habits: store)
                let reached = verdict.uniqueSkill?.reference.invocationName ?? "none"
                report.append("  ask  \(trip.id)[\(index)] \(leg.say) -> \(reached)")
                if reached == "search_web" {
                    wrong.append("\(trip.id)[\(index)] \"\(leg.say)\" reached search_web")
                }
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// THE TWINS, ON THE STAGE THAT MAKES THEM HARD. A video playing in the page
    /// and music playing in the app, one word apart — each sentence must reach
    /// its own surface, uniquely, on the confidence lane.
    @Test func theTransportTwinsSeparateAcrossTheCorpus() throws {
        guard let snapshot = try Self.snapshot() else { return }
        let store = RoutingHabitStore()
        var report: [String] = []
        var wrong: [String] = []

        for (_, trip) in BrowsingTrip.corpus(under: Self.tripsRoot).trips
        where trip.stage.musicPlaying == true {
            for (index, leg) in trip.legs.enumerated() {
                guard leg.pending == nil,
                      let wanted = leg.routing?.skill,
                      wanted == "control_media" || wanted == "control_playback"
                else { continue }
                let measured = Self.measure(
                    trip: trip, index: index, leg: leg,
                    wanted: leg.routing!, snapshot: snapshot, store: store)
                report.append(measured.line)
                let reached = measured.winner?.reference.invocationName
                if reached != wanted {
                    wrong.append(
                        "\(trip.id)[\(index)] \"\(leg.say)\" reached \(reached ?? "none"), not \(wanted)")
                }
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }
}
