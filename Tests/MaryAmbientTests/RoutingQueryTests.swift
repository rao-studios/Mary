//
//  RoutingQueryTests.swift
//  MaryAmbientTests
//
//  WHAT: Utterance + world + history compose one embedding query.
//  OUT:  RoutingQuery.compose
//

import Testing
@testable import MaryAmbient

@Suite struct RoutingQueryTests {

    @Test func theUtteranceLeadsTheQuery() {
        let query = RoutingQuery.compose(utterance: "play the RAO playlist")
        #expect(query == "play the RAO playlist")
    }

    @Test func liveWorldAndHistoryAppendAsClippedLines() {
        let query = RoutingQuery.compose(
            utterance: "play the RAO playlist",
            world: .init(
                leadApplicationID: "xcode",
                leadTitle: "Xcode",
                frontmostApplicationID: "xcode",
                playerRunning: true,
                playerName: "Music",
                selectionSubject: nil,
                leadFact: "main.swift"),
            recentUserTurns: ["hello", "what is playing"])
        #expect(query.hasPrefix("play the RAO playlist"))
        #expect(query.contains("lead: Xcode"))
        #expect(query.contains("player: running (Music)"))
        #expect(query.contains("fact: main.swift"))
        #expect(query.contains("recent: hello | what is playing"))
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
