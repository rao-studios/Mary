//
//  RoutingQueryTests.swift
//  MaryAmbientTests
//
//  WHAT: Utterance + live snapshot + history compose one embedding query.
//  OUT:  RoutingQuery.compose
//

import Testing
@testable import MaryAmbient

@Suite struct RoutingQueryTests {

    @Test func theUtteranceLeadsTheQuery() {
        let query = RoutingQuery.compose(utterance: "play the RAO playlist")
        #expect(query == "play the RAO playlist")
    }

    @Test func liveSnapshotAndHistoryAppendAsClippedLines() {
        let query = RoutingQuery.compose(
            utterance: "play the RAO playlist",
            world: AmbientWorld.Snapshot(
                sense: .workspace,
                attention: .applications,
                subject: "main.swift",
                applicationID: "com.apple.dt.Xcode"),
            recentUserTurns: ["hello", "what is playing"])
        #expect(query.hasPrefix("play the RAO playlist"))
        #expect(query.contains("lead: Xcode"))
        // A workspace world names its subject; only a highlight is a selection.
        #expect(query.contains("subject: main.swift"))
        #expect(query.contains("recent: hello | what is playing"))
        #expect(!query.contains("player:"))
        #expect(!query.contains("fact:"))
        #expect(!query.contains("frontmost:"))
    }

    @Test func historyKeepsOnlyTheLastFewTurns() {
        let query = RoutingQuery.compose(
            utterance: "now",
            recentUserTurns: ["one", "two", "three", "four"])
        #expect(query.contains("two | three | four"))
        #expect(!query.contains("one"))
    }
}
