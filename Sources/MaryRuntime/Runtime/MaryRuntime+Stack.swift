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
import MaryPlugin
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
            voiceID: "\(config.seerVoice)_neutral",
            retrievalScope: { retrievalScope(ownerID: $0) })
        await seerTTS.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerVision.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerComplete.configure(
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

    /// The hosted annotator over the app's own complete lane.
    ///
    /// A FACTORY RATHER THAN A LITERAL, because `seerComplete` is internal to
    /// this module and `mary-corpus-probe annotate` has to build the SAME
    /// annotator the app wires — a probe that constructed its own client
    /// would be verifying a different object than the one that ships.
    /// Spoken turns stay on `seerChat` (`/v1/chat/completions`); this
    /// factory must not be reused as a voice.
    package static func makeSeerUnitAnnotator() -> SeerUnitAnnotator {
        SeerUnitAnnotator(complete: seerComplete)
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
        // AND DELIBERATELY NOT THE LEARNING SINKS. Archiving used to install
        // them here, and the pairing was itself a defect: pausing archiving
        // switched off LEARNING as well, so `knownContentHash` answered nil
        // forever and no edit was distinguishable from a first sighting. The
        // corpus has since returned and keeps that separation — it installs
        // its own sink in `installCorpusPipeline` and answers to its own
        // switch, so pausing memory never costs Mary the ability to tell a
        // changed file from a new one.
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
    ///
    /// TWO PARAMETERS AND NOT ONE, for the same reason the two functions are
    /// separate: a caller that had to pass a single `enabled` could not say
    /// "keep archiving, but this person wants their words to stay on the
    /// device", which is exactly the combination the Brain card now offers.
    package static func connectSeerToBrain(chat: Bool, archiving: Bool) async {
        await connectSeerVoice(enabled: chat)
        await connectTotemDepositor(enabled: archiving)
    }

    /// WHETHER THE SEER CHAT LANE CARRIES TURNS — the one spelling of a
    /// question four call sites ask.
    ///
    /// TWO CONDITIONS, AND THEY ARE DIFFERENT QUESTIONS. `seerEnabled` is
    /// about the SERVER: is the local stack the user's to run, is Mary signed
    /// in. The Brain card's choice is about WHERE THE WORDS GO, which is the
    /// user's own question and the one the card's title asks out loud. Either
    /// one off keeps the turn on the device.
    ///
    /// THE CHOICE COMES FROM `engineChoiceBox`, not from config, because the
    /// callers that need this answer have no config in hand and because the
    /// picker must act on the value the person just selected — the config
    /// update it sends has not landed yet when the re-wire runs.
    package static func seerCarriesTurns(seerEnabled: Bool) -> Bool {
        seerCarriesTurns(
            engine: engineChoiceBox.withLock { $0 }, seerEnabled: seerEnabled)
    }

    /// The rule itself, free of the box — so a test can state the truth table
    /// without writing to a global that every other suite shares.
    package static func seerCarriesTurns(
        engine: LLMEngineChoice, seerEnabled: Bool
    ) -> Bool {
        engine == .hosted && seerEnabled
    }

    /// Apply the Brain card's choice: wire or unwire the Seer chat lane, then
    /// warm the on-device engine. Returns user-facing error text, or nil.
    ///
    /// THE ENGINE IS ALWAYS THE LOCAL ONE, and that is not the bug it looks
    /// like. Seer's chat has no tool support — verified, and the reason Lane B
    /// stays on the device — so hosted mode moves the SPOKEN pass to the
    /// server while the ACTING pass still runs here, and the local engine is
    /// also what carries the whole turn when the server is unreachable. There
    /// is no second engine type to construct.
    ///
    /// WHAT THE CHOICE ACTUALLY CHANGES IS THE WIRING, and until now it changed
    /// nothing at all: both arms of a `switch` built the same engine, the Seer
    /// lane was gated on `seerEnabled` alone, and so selecting "Local (on
    /// device)" left every word going to the server anyway. The only
    /// observable difference was a warming message. For a setting whose own
    /// title is "where the words go", that was the wrong way round to be
    /// broken.
    package static func applyEngine(
        _ choice: LLMEngineChoice, localModelID: String, seerEnabled: Bool
    ) async -> String? {
        engineChoiceBox.withLock { $0 = choice }
        await connectSeerVoice(enabled: seerCarriesTurns(seerEnabled: seerEnabled))
        let engine = MaryLocalEngine(modelID: localModelID)
        await brain.setEngine(engine)
        // CHECKED BEFORE WARMING, because the failure it prevents is not
        // catchable. A missing Metal library surfaces as a C++
        // `std::runtime_error` thrown out of MLX, which does not arrive as a
        // Swift error — the `catch` below never sees it and the process dies.
        // Reading the search path costs four `fileExists` calls and turns an
        // unrecoverable crash into a sentence naming the script to run.
        // THE ANNOTATOR FOLLOWS THE CHOICE, and it is the one job the hosted
        // lane is strictly better at. Summarising a unit needs no tools —
        // which is why it uses `/v1/complete` rather than the persona chat
        // lane — while the on-device engine requires exclusive generation
        // and would make a background summary queue behind the user's own
        // turn. On device, units keep their structure and go without a
        // précis, and the ledger says why.
        let hosted = seerCarriesTurns(engine: choice, seerEnabled: seerEnabled)
        await unitIndexer.setAnnotator(
            hosted ? makeSeerUnitAnnotator() : InferenceUnitAnnotator(engine: engine))
        // A relaunch resumes from the durable manifest instead of treating
        // every file in the project as a first sighting.
        await unitIndexer.setManifestLoader { projectID in
            await totemContext.loadUnitManifest(projectID: projectID)
        }

        guard MaryGPU.report().isSatisfied else { return MaryGPU.remedy() }
        do {
            try await brain.warmup()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

}
