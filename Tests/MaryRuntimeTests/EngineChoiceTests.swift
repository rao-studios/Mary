//
//  EngineChoiceTests.swift
//  MaryRuntimeTests
//
//  WHAT: The three-way backend choice — its wire contract with Sewn, its
//        tolerance of a config written before the split, and the rule that
//        every lane rides Sewn.
//  OUT:  LLMEngineChoice / applyEngine
//

import Foundation
import Testing
import MaryBrain
@testable import MaryRuntime

@Suite struct EngineChoiceTests {

    // MARK: - The wire

    /// These strings ARE the contract with Sewn's `LLMProvider`. A rename on
    /// either side silently reroutes every turn, so both sides pin them.
    @Test func rawValuesMatchSewnsProviderEnum() {
        #expect(LLMEngineChoice.mistral.rawValue == "mistral")
        #expect(LLMEngineChoice.local.rawValue == "local")
        #expect(LLMEngineChoice.tinker.rawValue == "tinker")
        #expect(Set(LLMEngineChoice.allCases.map(\.rawValue)) == Set(["mistral", "local", "tinker"]))
    }

    // MARK: - The rule

    /// EVERY LANE RIDES SEWN NOW. The choice says which backend Sewn uses; it
    /// never decides whether Sewn is used, because there is no second engine
    /// in this process any more.
    @Test(arguments: [
        (LLMEngineChoice.mistral, true, true),
        (LLMEngineChoice.mistral, false, false),
        (LLMEngineChoice.local, true, true),
        (LLMEngineChoice.local, false, false),
        (LLMEngineChoice.tinker, true, true),
        (LLMEngineChoice.tinker, false, false),
    ])
    func onlyTheServerToggleDecidesWhetherSewnCarriesTheTurn(
        _ engine: LLMEngineChoice, _ sewnEnabled: Bool, _ expected: Bool
    ) {
        #expect(
            MaryRuntime.sewnCarriesTurns(engine: engine, sewnEnabled: sewnEnabled) == expected)
        #expect(
            MaryRuntime.sewnCarriesSkills(engine: engine, sewnEnabled: sewnEnabled) == expected)
        #expect(
            MaryRuntime.sewnCarriesCoding(engine: engine, sewnEnabled: sewnEnabled) == expected)
    }

    /// On-device is a Sewn backend, not a bypass: choosing it must still leave
    /// the turn on the server, which is the whole point of the move.
    @Test func choosingOnDeviceStillGoesThroughSewn() {
        #expect(MaryRuntime.sewnCarriesTurns(engine: .local, sewnEnabled: true))
        #expect(LLMEngineChoice.local.isOnDevice)
        #expect(!LLMEngineChoice.mistral.isOnDevice)
    }

    // MARK: - The defaults

    @Test func aFreshInstallUsesMistralOnEveryLane() {
        let state = ConfigService.Center.State()
        #expect(state.llmEngine == .mistral)
        #expect(state.skillEngine == .mistral)
        #expect(state.codingEngine == .mistral)
        #expect(state.sewnEnabled)
        #expect(state.codingAgentEnabled == false)
    }

    @Test func theDecodeFallbackAgreesWithTheDeclaredDefault() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self, from: Data("{}".utf8))
        #expect(restored.llmEngine == ConfigService.Center.State().llmEngine)
        #expect(restored.skillEngine == ConfigService.Center.State().skillEngine)
        #expect(restored.codingEngine == ConfigService.Center.State().codingEngine)
    }

    // MARK: - The migration

    /// A CONFIG WRITTEN BEFORE THE SPLIT SAYS "hosted". Decoding must not
    /// throw: Granite re-seeds every setting when a stored State fails to
    /// decode, so a strict enum here would wipe voices, projects and servers.
    @Test func theOldHostedValueBecomesMistralWithoutLosingTheRest() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self,
            from: Data(#"{"llmEngine":"hosted","skillEngine":"hosted","codingEngine":"hosted","voice":"af_bella","sewnPort":9999}"#.utf8))
        #expect(restored.llmEngine == .mistral)
        #expect(restored.skillEngine == .mistral)
        #expect(restored.codingEngine == .mistral)
        // The rest of the file survived, which is what the tolerance is for.
        #expect(restored.voice == "af_bella")
        #expect(restored.sewnPort == 9999)
    }

    /// The pre-split on-device value keeps its meaning — it now names Sewn's
    /// on-device backend rather than an in-process one.
    @Test func theOldLocalValueStillMeansOnDevice() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self,
            from: Data(#"{"llmEngine":"local","skillEngine":"local"}"#.utf8))
        #expect(restored.llmEngine == .local)
        #expect(restored.skillEngine == .local)
    }

    @Test func anUnknownBackendFallsBackRatherThanDiscardingTheConfig() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self,
            from: Data(#"{"llmEngine":"gemini","sewnPort":8123}"#.utf8))
        #expect(restored.llmEngine == .mistral)
        #expect(restored.sewnPort == 8123)
    }

    @Test func anExplicitChoiceSurvivesRestore() throws {
        let restored = try JSONDecoder().decode(
            ConfigService.Center.State.self,
            from: Data(#"{"llmEngine":"tinker","skillEngine":"local"}"#.utf8))
        #expect(restored.llmEngine == .tinker)
        #expect(restored.skillEngine == .local)
    }
}

/// The Metal library a GPU-serving checkout needs beside its binary. SwiftPM
/// has no Metal step, so building a server means building this too — without
/// it the first model load dies inside MLX, past any Swift error handling.
@Suite struct StackMetallibTests {

    @Test func aCheckoutWithNoScriptNeedsNoMetalStep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LocalStackManager.metallibScript(in: directory.path) == nil)
    }

    @Test(arguments: ["scripts/build-metallib.sh", "build-metallib.sh"])
    func theScriptIsFoundAtEitherPlaceTheSiblingsKeepIt(_ relative: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let script = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("#!/bin/bash\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(LocalStackManager.metallibScript(in: directory.path) == script.path)
    }

    /// A script that is present but not executable would fail at spawn time;
    /// reporting "no metal step" for it hides the real problem.
    @Test func aNonExecutableScriptIsNotTreatedAsUsable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("build-metallib.sh")
        try Data("#!/bin/bash\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: script.path)
        #expect(LocalStackManager.metallibScript(in: directory.path) == nil)
    }
}
