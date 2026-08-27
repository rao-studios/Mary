//
//  MaryRuntime+Stack.swift
//  Mary
//
//  Moved verbatim from MaryRuntime.swift (phase 3): the Seer/Totem stack
//  appliers (applyServers, applySeerTransport, applySeerAccount,
//  connectSeerVoice, connectTotemDepositor, resetAmbientMemory,
//  connectSeerToBrain, applyEngine, makeTotemReader and the totemGRPCPort it
//  reads), plus the appliers that group with them: applyPronunciations, the
//  spoken-register funcs, and applyCodingAgent.
//
//  No behavior change. `totemGRPCPort`'s private(set) writer (applyServers)
//  moved with it; `totemArchivingEnabledBox` (written by
//  connectTotemDepositor) lives in +Focus, internal for the split.
//

import MaryBrain
import MaryAdapters
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {

    /// Feed the user's Settings-defined pronunciation overrides into Kokoro.
    /// Called at boot and whenever Settings saves.
    package static func applyPronunciations(_ byWord: [String: String]) async {
        for (word, ipa) in byWord {
            await kokoro.addCustomPronunciation(word, ipa: ipa)
        }
    }

    // MARK: - Spoken register (casual ↔ task)

    /// The configured style; `.auto` enables per-turn register switching.
    /// Written at boot and on Settings save from the config store.
    nonisolated(unsafe) package static var styleSelection: SpeechStyleSelection = .auto

    /// A spoken turn is starting — rest in the chat register.
    /// Registers are a Kokoro concept; Mistral carries emotion in the voice.
    static func spokenTurnBegan() async {
        guard styleSelection == .auto, activeTTSBackend == .kokoro else { return }
        await speaker.setStyle(.chat)
    }

    /// The turn invoked an effectful Skill — shift to the neutral task register for
    /// the rest of the reply.
    static func spokenSkillUsed() async {
        guard styleSelection == .auto, activeTTSBackend == .kokoro else { return }
        await speaker.setStyle(.neutral)
    }

    // MARK: - Seer/Totem stack appliers

    /// Point the stack at the configured checkouts/ports and the chat client
    /// at the right base URL + totem identity. Running servers keep running;
    /// spec changes apply on restart (Servers sheet).
    /// Where Totem's direct gRPC lives right now — read by makeTotemReader.
    nonisolated(unsafe) private(set) static var totemGRPCPort = ServerSpec.Defaults.totemGRPCPort

    /// A fresh read client for inspector/library queries (connections are
    /// per-call, so clients are cheap to make at the current port).
    package static func makeTotemReader() -> TotemDirectClient {
        TotemDirectClient(port: totemGRPCPort)
    }

    package static func applyServers(config: ConfigService.Center.State, nodeID: String) async {
        totemGRPCPort = config.totemGRPCPort
        await localStack.configure([
            .seer(
                checkoutPath: config.seerCheckoutPath,
                port: config.seerPort,
                grpcPort: config.seerGRPCPort),
            .totem(
                checkoutPath: config.totemCheckoutPath,
                port: config.totemPort,
                grpcPort: config.totemGRPCPort,
                mothershipGRPCPort: config.seerGRPCPort,
                nodeID: nodeID,
                graphBackend: config.totemGraphBackend),
        ])
        await totemContext.configure(port: config.totemGRPCPort)
        // Both transports get the SAME scope closure — they wrap the identical
        // ChatRequest, so scoping one and not the other would look like a
        // Settings-dependent bug with no cause.
        await seerChat.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!,
            personalTotemID: nodeID,
            chatModel: config.seerChatModel,
            retrievalScope: { retrievalScope(ownerID: $0) })
        await seerRealtime.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!,
            personalTotemID: nodeID,
            chatModel: config.seerChatModel,
            voiceID: "\(config.voice)_neutral",
            retrievalScope: { retrievalScope(ownerID: $0) })
        await seerTTS.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerTotems.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
    }

    /// Route Seer-mode turns over the classic SSE lane or the realtime
    /// WebSocket. The classic client stays wired regardless — it is both the
    /// default and the realtime route's fallback. Mirrors applyTTSBackend:
    /// call at boot (after the Seer stack) and from the Settings binding.
    package static func applySeerTransport(_ choice: SeerTransportChoice) async {
        await brain.setSeerRealtime(choice == .realtime ? seerRealtime : nil)
    }

    /// Sign in with the configured account. Returns error text or nil.
    package static func applySeerAccount(email: String, password: String, seerPort: Int) async -> String? {
        await seerSession.configure(
            baseURL: URL(string: "http://127.0.0.1:\(seerPort)")!,
            email: email,
            password: password)
        return await seerSession.signIn()
    }

    /// Wire (or unwire) Seer as the brain's VOICE.
    static func connectSeerVoice(enabled: Bool) async {
        await brain.setSeerChat(enabled ? seerChat : nil)
    }

    /// Wire (or unwire) Totem as the brain's ARCHIVE.
    static func connectTotemDepositor(enabled: Bool) async {
        totemArchivingEnabledBox.withLock { $0 = enabled }
        await brain.setDepositor(enabled ? totemContext : nil)
        // THE LEARNING SINKS ARE NOT IN THIS CUT. Archiving used to install
        // three of them here — an observation indexer, a project indexer, a
        // unit indexer feeding the style corpus — and the pairing was itself a
        // defect: pausing archiving switched off LEARNING as well, so
        // `knownContentHash` answered nil forever and no edit was ever
        // distinguishable from a first sighting. When the corpus returns it
        // installs its own sinks, on their own switch.
    }

    /// Resets the ephemeral awareness and cancels any pending application
    /// schema flush. Durable Totem documents are cleared by the caller first.
    package static func resetAmbientMemory() async {
        AmbientContextStore.shared.clear()
        // AND THE BEHAVIORAL RECORD, which is the part a person actually
        // means. Ambient facts expire on their own; episodes are the durable
        // thing, in plaintext, and "reset my memory" that left them on disk
        // would be the one place this promise was not kept.
        await behavioralStore.purge()
    }

    /// Wire (or unwire) both. Split above because they were welded: you could
    /// not keep the Seer voice while pausing archiving, which is the first
    /// thing anyone wants when memory starts answering for the live document.
    /// The brain re-checks readiness every turn, so a dead server degrades to
    /// engine-only turns without re-wiring.
    package static func connectSeerToBrain(enabled: Bool) async {
        await connectSeerVoice(enabled: enabled)
        await connectTotemDepositor(enabled: enabled)
    }

    /// Swap the brain's engine to match configuration and warm it.
    /// Returns a user-facing error string on failure, nil on success.
    package static func applyEngine(
        _ choice: LLMEngineChoice, localModelID: String, hostedModelID: String
    ) async -> String? {
        let engine: any InferenceEngine
        switch choice {
        case .local:
            engine = MaryLocalEngine(modelID: localModelID)
        case .hosted:
            // THE HOSTED LANE IS SEER'S, and Seer's chat has no tool support
            // — verified, and the reason Lane B stays local. Choosing hosted
            // swaps the SPOKEN pass to the server; the acting pass still runs
            // on the device, which is also why there is no second engine type
            // to construct here.
            engine = MaryLocalEngine(modelID: localModelID)
            _ = hostedModelID
        }
        await brain.setEngine(engine)
        do {
            try await brain.warmup()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

}
