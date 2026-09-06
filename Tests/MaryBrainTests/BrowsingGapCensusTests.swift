//
//  BrowsingGapCensusTests.swift
//  MaryBrainTests
//
//  WHAT: The things a person says while browsing that the corpus does not
//        cover, rehearsed through the real gates — a census of what reaches
//        nothing, the wrong skill, or a skill that is not built yet.
//  OUT:  a printed table; the findings become trips
//  PIN:  A CORPUS ONLY MEASURES WHAT SOMEBODY THOUGHT TO WRITE DOWN. Forty
//        trips were authored from the engine's own verbs; this walks in from the
//        other side — from what a person actually says at a browser — and asks
//        each sentence where it would go. A sentence that reaches NOTHING is a
//        missing verb. One that reaches the WRONG skill is a routing finding.
//        One that reaches a PENDING skill is a known gap with a round already
//        named. The census asserts nothing about which is which: it prints, and
//        a person decides what becomes a trip. Calibration-gated, like every
//        measurement against the real embedding model.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct BrowsingGapCensusTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    /// What a person says at a browser, grouped by what they are doing. None
    /// of these is a trip yet; that is the point.
    static let census: [(group: String, phrases: [String])] = [
        ("navigate", [
            "go home", "take me back two pages", "stop loading", "go to the top of the page",
            "scroll to the bottom", "zoom in", "make the text bigger", "reset the zoom",
            "go back to the search results",
        ]),
        ("tabs", [
            "close this tab", "open a new tab", "switch to the next tab",
            "reopen the tab I just closed", "how many tabs do I have open",
            "close all the other tabs", "duplicate this tab", "move this tab to a new window",
        ]),
        ("page", [
            "find the word budget on this page", "select all the text",
            "copy the link to this page", "what's the address of this page",
            "print this page", "save this page", "bookmark this page",
            "translate this page", "show me the reader view", "refresh",
        ]),
        ("read", [
            "read me the first paragraph", "read the comments",
            "what are the headings on this page", "is there a video on this page",
            "how long is this article", "read me the next section",
        ]),
        ("forms", [
            "fill in my email address", "check the box that says remember me",
            "pick the second option in the dropdown", "submit the form",
            "clear the search box", "press the blue button",
        ]),
        ("media", [
            "turn the volume up a bit", "play it from the start", "skip ahead thirty seconds",
            "turn on the captions", "play the next video", "mute it and go back to my editor",
        ]),
        ("downloads and history", [
            "download that file", "open my downloads", "what was the last page I was on",
            "show my browsing history",
        ]),
        ("across surfaces", [
            "search for this on youtube instead", "open this in the music app",
            "send this page to my notes",
        ]),
    ]

    private static func snapshot() throws -> AbilityRuntime.Snapshot? {
        BrowsingRehearsalSnapshot.load()
    }

    /// The whole census, rehearsed with a browser in front, printed as a table.
    @Test func whereEachThingAPersonSaysWouldGo() throws {
        guard let snapshot = try Self.snapshot() else { return }
        let store = RoutingHabitStore()
        let classes = BrowsingRehearsalSnapshot.targetClasses(front: "browser", in: snapshot)
        // AN EMPTY STAGE MEASURES NOTHING, and this is the line that caught it.
        #expect(!classes.isEmpty, "the stage resolved to no target classes — the snapshot holds no applications")
        let browsing = Set(snapshot.skills
            .filter { $0.ability.id.rawValue == "browsing" }
            .map(\.reference.invocationName))

        // WHAT THE SNAPSHOT ACTUALLY HOLDS, printed before anything is judged
        // by it: a census run against an empty stage measures nothing.
        let profiles = snapshot.plugins.applicationProfiles.map(\.id).sorted()
        var lines: [String] = [
            "", "PROFILES (\(profiles.count)): \(profiles.joined(separator: ", "))",
            "CENSUS — with a browser in front (classes: \(classes.sorted().joined(separator: ",")))", ""]
        var nothing: [String] = [], elsewhere: [String] = [], modelRound: [String] = []
        for (group, phrases) in Self.census {
            lines.append("── \(group)")
            for phrase in phrases {
                let arb = AbilityRosterRehearsal.arbitration(
                    snapshot: snapshot, utterance: phrase, targetClasses: classes, habits: store)
                let offered = Set(arb.trace.selected.map(\.reference.invocationName))
                let verdict = TurnTriage.verdict(
                    query: phrase, registry: snapshot, offeredNames: offered, habits: store)
                let winner = verdict.uniqueSkill?.reference.invocationName
                let shape = verdict.uniqueSkill.flatMap {
                    EmbeddingRouting.confidenceShape(of: $0, utterance: phrase)
                }
                let top = verdict.skillAffinities.sorted { $0.value > $1.value }.prefix(3)
                    .map { "\(snapshot.skill(id: $0.key)?.reference.invocationName ?? $0.key.rawValue) \(String(format: "%.2f", $0.value))" }
                    .joined(separator: ", ")
                let lane: String
                if let winner, shape != nil { lane = "confidence" }
                else if winner != nil { lane = "model" }
                else if offered.isEmpty { lane = "NOTHING" }
                else { lane = "model (\(offered.count) offered)" }
                let where_ = winner.map { browsing.contains($0) ? $0 : "\($0) ← not browsing" } ?? "—"
                lines.append(String(
                    format: "  %-44@ %-10@ %-22@ %@",
                    (phrase.count > 42 ? String(phrase.prefix(42)) + "…" : phrase) as NSString,
                    (verdict.intent?.rawValue ?? "nil") as NSString,
                    lane as NSString,
                    "\(where_)  ·  \(top)" as NSString))
                if offered.isEmpty { nothing.append(phrase) }
                else if let winner, !browsing.contains(winner) { elsewhere.append("\(phrase) → \(winner)") }
                else if winner == nil { modelRound.append(phrase) }
            }
            lines.append("")
        }
        lines.append("REACHES NOTHING (\(nothing.count)): " + nothing.joined(separator: " | "))
        lines.append("REACHES ANOTHER SURFACE (\(elsewhere.count)): " + elsewhere.joined(separator: " | "))
        lines.append("NO UNIQUE WINNER, MODEL ROUND (\(modelRound.count)): " + modelRound.joined(separator: " | "))
        print(lines.joined(separator: "\n"))
        #expect(!lines.isEmpty)
    }
}
