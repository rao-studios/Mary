//
//  EndpointHoldTests.swift
//  MaryVoiceTests
//
//  WHAT: Which endings earn a longer pause before the endpoint.
//  OUT:  EndpointHold.extraSilence
//

import Testing
@testable import MaryVoice

@Suite struct EndpointHoldTests {

    @Test(arguments: ["open the", "search for", "play something by", "open Safari and",
                      "um", "go to the,", "open my"])
    func danglingEndingsWait(_ partial: String) {
        #expect(EndpointHold.extraSilence(forPartial: partial) == EndpointHold.danglingExtension)
    }

    /// Particles end real commands; a finished phrase keeps the normal hangover.
    @Test(arguments: ["open Safari", "turn it on", "log in", "turn it up",
                      "what time is it", "Hey Mary.", ""])
    func finishedEndingsDoNot(_ partial: String) {
        #expect(EndpointHold.extraSilence(forPartial: partial) == 0)
    }
}
