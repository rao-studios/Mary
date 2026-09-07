//
//  SpokenDurationTests.swift
//  MaryPluginTests
//
//  WHAT: The spoken lengths of time a seek takes, and which way each points.
//

import Testing
@testable import MaryPlugin

@Suite struct SpokenDurationTests {

    @Test func aMoveBackwardsIsNegative() {
        #expect(SpokenDuration.seek(in: "back two minutes in the video") == .by(-120))
        #expect(SpokenDuration.seek(in: "rewind thirty seconds") == .by(-30))
        #expect(SpokenDuration.seek(in: "can you go back a minute") == .by(-60))
    }

    @Test func aMoveForwardsIsPositive() {
        #expect(SpokenDuration.seek(in: "skip ahead 30 seconds") == .by(30))
        #expect(SpokenDuration.seek(in: "forward a minute and a half") == .by(90))
        #expect(SpokenDuration.seek(in: "skip half a minute") == .by(30))
    }

    @Test func aDestinationIsAbsolute() {
        #expect(SpokenDuration.seek(in: "go to three minutes in the video") == .to(180))
        #expect(SpokenDuration.seek(in: "three minutes in") == .to(180))
        #expect(SpokenDuration.seek(in: "jump to 1:30") == .to(90))
        #expect(SpokenDuration.seek(in: "at 1:02:03") == .to(3723))
        #expect(SpokenDuration.seek(in: "go back to two minutes") == .to(120))
    }

    /// A NUMBER WITHOUT A UNIT IS NOT A TIME. "Go to 90" could be a page or a percent.
    @Test func aBareNumberIsNotATime() {
        #expect(SpokenDuration.seek(in: "go to 90") == nil)
        #expect(SpokenDuration.seek(in: "skip to halfway") == nil)
        #expect(SpokenDuration.seek(in: "pause the video") == nil)
    }

    @Test func aLengthIsSpokenAsAClock() {
        #expect(SpokenDuration.clock(120) == "2:00")
        #expect(SpokenDuration.clock(-30) == "0:30")
        #expect(SpokenDuration.clock(3723) == "1:02:03")
    }
}
