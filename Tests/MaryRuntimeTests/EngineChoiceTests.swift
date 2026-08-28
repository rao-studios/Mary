//
//  EngineChoiceTests.swift
//  MaryRuntimeTests
//
//  WHERE THE WORDS GO — the one setting a person opens Settings to answer,
//  and the one that used to answer wrongly.
//
//  WHAT THIS IS THE REGRESSION FOR. `LLMEngineChoice` was inert. Both arms of
//  `applyEngine` built the same `MaryLocalEngine`, the Seer chat lane was
//  wired on `seerEnabled` alone, and so selecting "Local (on device)" left
//  every turn going to the server. The only observable difference in the whole
//  build was a warming message. Nothing failed; the switch simply did not do
//  the thing it named, which is the worst shape for a setting whose subject is
//  where a person's words are sent.
//
//  THE TRUTH TABLE IS THE TEST. Two independent conditions — the server is the
//  user's to use, and the user wants the words to go there — and the only
//  combination that carries a turn to Seer is both. Stated here rather than
//  inferred from four call sites, because the four call sites are exactly what
//  drifted.
//

import Foundation
import Testing
import MaryBrain
@testable import MaryRuntime

@Suite struct EngineChoiceTests {

    // MARK: - The rule

    @Test(arguments: [
        (LLMEngineChoice.hosted, true, true),
        (LLMEngineChoice.hosted, false, false),
        (LLMEngineChoice.local, true, false),
        (LLMEngineChoice.local, false, false),
    ])
    func onlyHostedAndEnabledSendsTheTurnToSeer(
        _ engine: LLMEngineChoice, _ seerEnabled: Bool, _ expected: Bool
    ) {
        #expect(
            MaryRuntime.seerCarriesTurns(engine: engine, seerEnabled: seerEnabled)
                == expected)
    }

    /// THE ONE THAT WAS BROKEN, called out on its own because a row in a table
    /// is easy to read past. Choosing on-device must keep the turn on the
    /// device even when the server is up, signed in and perfectly willing.
    @Test func choosingOnDeviceKeepsTheTurnOffSeerEvenWhenSeerIsAvailable() {
        #expect(
            MaryRuntime.seerCarriesTurns(engine: .local, seerEnabled: true) == false)
    }

    // MARK: - The default

    /// HOSTED IS THE DEFAULT because it is what the build already did:
    /// `seerEnabled` and `autoStartServers` default true and the turn loop
    /// takes the Seer path whenever the server answers. A fresh install that
    /// read "Local (on device)" was describing a turn that had gone to Seer.
    @Test func aFreshInstallPrefersSeer() {
        #expect(ConfigService.Center.State().llmEngine == .hosted)
        #expect(ConfigService.Center.State().seerEnabled)
        #expect(
            MaryRuntime.seerCarriesTurns(
                engine: ConfigService.Center.State().llmEngine,
                seerEnabled: ConfigService.Center.State().seerEnabled))
    }

    /// A STORED CONFIG FROM BEFORE THIS CHANGE has no `llmEngine` key only if
    /// it never had one; anything already written keeps what it says. The
    /// tolerant decode's fallback is what a fresh restore lands on, and it must
    /// agree with the struct's own default or the two disagree about a first
    /// run depending on whether a file existed.
    @Test func theDecodeFallbackAgreesWithTheDeclaredDefault() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self, from: Data("{}".utf8))
        #expect(restored.llmEngine == ConfigService.Center.State().llmEngine)
    }

    /// AND AN EXPLICIT CHOICE SURVIVES THE ROUND TRIP — the default must not
    /// quietly overwrite a person who went and picked on-device.
    @Test func anExplicitOnDeviceChoiceIsNotOverriddenByTheNewDefault() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self,
            from: Data(#"{"llmEngine":"local"}"#.utf8))
        #expect(restored.llmEngine == .local)
    }
}
