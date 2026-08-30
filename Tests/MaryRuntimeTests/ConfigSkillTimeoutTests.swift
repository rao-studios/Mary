//
//  ConfigSkillTimeoutTests.swift
//  MaryRuntimeTests
//
//  The Ability runs sheet's 1…10 s cap is a stored setting. A missing key
//  restores the 2 s default; out-of-range values clamp rather than throw.
//

import Foundation
import Testing
import MaryBrain
@testable import MaryRuntime

@Suite struct ConfigSkillTimeoutTests {

    @Test func freshStateDefaultsToTwoSeconds() {
        #expect(ConfigService.Center.State().skillRunTimeoutSeconds == 2)
        #expect(
            ConfigService.Center.State().skillRunTimeoutSeconds
                == AbilityRuntime.ordinarySkillTimeoutDefault)
    }

    @Test func missingKeyRestoresTheDefault() throws {
        let restored = try decode("{}")
        #expect(restored.skillRunTimeoutSeconds == 2)
    }

    @Test func storedChoiceSurvivesTheRoundTrip() throws {
        var state = ConfigService.Center.State()
        state.skillRunTimeoutSeconds = 7
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self, from: data)
        #expect(restored.skillRunTimeoutSeconds == 7)
    }

    @Test func decodeClampsToOneThroughTen() throws {
        #expect(try decode(#"{"skillRunTimeoutSeconds": 0}"#).skillRunTimeoutSeconds == 1)
        #expect(try decode(#"{"skillRunTimeoutSeconds": 2}"#).skillRunTimeoutSeconds == 2)
        #expect(try decode(#"{"skillRunTimeoutSeconds": 11}"#).skillRunTimeoutSeconds == 10)
    }

    private func decode(_ json: String) throws -> ConfigService.Center.State {
        try JSONDecoder().decode(
            ConfigService.Center.State.self, from: Data(json.utf8))
    }
}
