//
//  CorpusPatternsTests.swift
//  MaryPluginTests
//
//  `capturesWithLines` IS `captures`'S SIBLING — same compiled/cached
//  expression, the position `captures` deliberately leaves out (see that
//  function's own header). These pin the arithmetic: a match on line one is
//  line one, a match after N newlines is line N+1, and a pattern that
//  matches nothing returns nothing rather than crashing on an empty range.
//

import Foundation
import Testing
@testable import MaryPlugin

@Suite struct CorpusPatternsTests {

    @Test func aMatchOnTheFirstLineIsLineOne() {
        let found = CorpusPatterns.capturesWithLines(
            #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: "func one() {}")
        #expect(found.map(\.name) == ["one"])
        #expect(found.map(\.line) == [1])
    }

    @Test func lineCountsNewlinesBeforeTheMatch() {
        let source = """
        // header
        struct A {
            func one() {}
            func two() {}
        }
        """
        let found = CorpusPatterns.capturesWithLines(
            #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: source)
        #expect(found.map(\.name) == ["one", "two"])
        #expect(found.map(\.line) == [3, 4])
    }

    @Test func noCaptureGroupMeansNoResult() {
        // A pattern with no group at all — `captures`' own contract requires
        // one, and this sibling honours the same refusal.
        let found = CorpusPatterns.capturesWithLines(#"\bfunc\b"#, in: "func one() {}")
        #expect(found.isEmpty)
    }

    @Test func emptyTextProducesNoMatches() {
        #expect(CorpusPatterns.capturesWithLines(#"\bfunc\s+(\w+)"#, in: "").isEmpty)
    }

    @Test func aNonCompilingPatternProducesNoMatchesRatherThanThrow() {
        // Unbalanced group — mirrors `captures`' own silence-on-failure
        // contract (this file's sibling header: "A FAILURE HERE IS SILENCE").
        #expect(CorpusPatterns.capturesWithLines("(unbalanced", in: "anything").isEmpty)
    }

    @Test func multipleMatchesOnTheSameLineAllReportThatLine() {
        let found = CorpusPatterns.capturesWithLines(
            #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: "func a() {}; func b() {}")
        #expect(found.map(\.name) == ["a", "b"])
        #expect(found.map(\.line) == [1, 1])
    }
}
