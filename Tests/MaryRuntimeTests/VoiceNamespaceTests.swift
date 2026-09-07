//
//  VoiceNamespaceTests.swift
//  MaryRuntimeTests
//
//  WHAT: Hosted character slug and on-device Kokoro voice are separate fields.
//  OUT:  Config voice namespaces
//  PIN:  A hosted slug must never be handed to Kokoro as a style file
//

import Foundation
import Testing
import MaryVoice
@testable import MaryRuntime

@Suite struct VoiceNamespaceTests {

    // MARK: - The split

    @Test func theHostedCharacterAndTheOnDeviceVoiceAreSeparateFields() {
        let state = ConfigService.Center.State()
        #expect(state.voice == "af_heart", "the on-device slot names a bundled embedding")
        #expect(state.sewnVoice == VoiceCharacter.marie.id, "the hosted slot names a server voice")
    }

    // MARK: - The migration

    private func decode(_ json: String) throws -> ConfigService.Center.State {
        try JSONDecoder().decode(ConfigService.Center.State.self, from: Data(json.utf8))
    }

    /// Every install written by the one-field build: the hosted slug sits in
    /// the slot boot hands to Kokoro. It must move, not merely be tolerated.
    @Test func aStoredHostedCharacterMovesOutOfTheOnDeviceSlot() throws {
        let state = try decode(#"{"voice":"fr_marie","ttsBackend":"sewn"}"#)
        #expect(state.voice == "af_heart", "Kokoro gets a voice it can actually load")
        #expect(state.sewnVoice == "fr_marie", "and the character the user chose is kept")
        #expect(state.ttsBackend == .sewn, "without disturbing the rest of the store")
    }

    @Test func anOnDeviceVoiceIsLeftAlone() throws {
        let state = try decode(#"{"voice":"am_adam","sewnVoice":"fr_marie"}"#)
        #expect(state.voice == "am_adam")
        #expect(state.sewnVoice == "fr_marie")
    }

    /// A store already split keeps its hosted choice — the migration must not
    /// overwrite a real `sewnVoice` from a stale shared field.
    @Test func anAlreadySplitStoreKeepsItsHostedChoice() throws {
        let state = try decode(#"{"voice":"fr_marie","sewnVoice":"fr_marie"}"#)
        #expect(state.voice == "af_heart")
        #expect(state.sewnVoice == "fr_marie")
    }

    /// The tolerant-decode rule this file must not break: a missing key never
    /// fails the restore, because a throw re-seeds every default at once.
    @Test func aMissingSewnVoiceKeyDecodesToTheDefaultCharacter() throws {
        let state = try decode(#"{"voice":"af_heart"}"#)
        #expect(state.sewnVoice == VoiceCharacter.marie.id)
    }

    // MARK: - The resolver

    /// A models directory holding `voices/<name>.json` for each given name.
    private func makeModelsDirectory(voices: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kokoro-\(UUID().uuidString)")
        let voicesDir = root.appendingPathComponent("voices")
        try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        for voice in voices {
            try Data("{}".utf8).write(to: voicesDir.appendingPathComponent("\(voice).json"))
        }
        return root
    }

    @Test func aBundledVoiceResolvesToItself() throws {
        let dir = try makeModelsDirectory(voices: ["af_heart", "am_adam"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MaryRuntime.onDeviceVoice(named: "am_adam", in: dir) == "am_adam")
    }

    /// The second line of defence: a hosted slug arriving by ANY route still
    /// brings the voice up rather than failing boot.
    @Test func aHostedCharacterIDFallsBackToTheDefaultVoice() throws {
        let dir = try makeModelsDirectory(voices: ["af_heart", "am_adam"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MaryRuntime.onDeviceVoice(named: "fr_marie", in: dir)
                == MaryRuntime.defaultKokoroVoice)
    }

    /// A bundle that stopped shipping `af_heart` still speaks — with whatever
    /// it does carry.
    @Test func aMissingDefaultFallsBackToAnyBundledVoice() throws {
        let dir = try makeModelsDirectory(voices: ["bf_alice"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MaryRuntime.onDeviceVoice(named: "fr_marie", in: dir) == "bf_alice")
    }

    /// Nothing to speak with is the one real failure, and it is reported as
    /// missing assets rather than thrown from inside the engine.
    @Test func anEmptyVoicesDirectoryResolvesToNothing() throws {
        let dir = try makeModelsDirectory(voices: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MaryRuntime.onDeviceVoice(named: "af_heart", in: dir) == nil)
    }
}
