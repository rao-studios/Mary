//
//  MaryRuntime+Stack.swift
//  MaryRuntime
//
//  WHAT: Seer/Totem stack appliers, spoken register, coding-engine install.
//  IN:   Settings / Servers sheet / applyEngine
//  OUT:  seerChat / seerRealtime / totemContext / InferenceEngine
//  PIN:  totemArchivingEnabledBox lives in +FocusSetup (internal for file split).
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

    /// Point stack at configured checkouts/ports. Running servers keep running.
    /// totemGRPCPort — read by makeTotemReader.
    nonisolated(unsafe) private(set) static var totemGRPCPort = ServerSpec.Defaults.totemGRPCPort
    nonisolated(unsafe) private(set) static var fleetGRPCPort = ServerSpec.Defaults.fleetGRPCPort

    /// A fresh read client for inspector/library queries (connections are
    /// per-call, so clients are cheap to make at the current port).
    package static func makeTotemReader() -> TotemDirectClient {
        TotemDirectClient(port: totemGRPCPort)
    }

    package static func makeFleetClient() -> FleetDirectClient {
        FleetDirectClient(port: fleetGRPCPort)
    }

    /// Point the Fleet dial at a node without booting the server stack —
    /// what `mary-life-probe` needs, and nothing else it does not.
    /// PIN: Lives here because `fleetGRPCPort`'s setter is file-private.
    package static func configureLifeAccess(nodeID: String, fleetGRPCPort port: Int) {
        fleetGRPCPort = port
        totemNodeIDBox.withLock { $0 = nodeID }
    }

    package static func applyServers(config: ConfigService.Center.State, nodeID: String) async {
        totemGRPCPort = config.totemGRPCPort
        fleetGRPCPort = config.fleetGRPCPort
        totemNodeIDBox.withLock { $0 = nodeID }
        lifeModeBox.withLock { $0 = config.lifeMode }
        await lifeEngine.setActsOnTurns(
            Set(config.lifeTurnDisciplines.map(AbilityID.init)))
        await lifeEngine.setMode(config.lifeMode)
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
            .fleet(
                checkoutPath: config.fleetCheckoutPath,
                port: config.fleetPort,
                grpcPort: config.fleetGRPCPort,
                totemGRPCPort: config.totemGRPCPort),
        ])
        await totemContext.configure(port: config.totemGRPCPort)
        // Both transports get the same scope closure — they wrap the same ChatRequest.
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
        await seerSkill.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerCode.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerTotems.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerProviders.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!)
        await seerEmbedding.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.seerPort)")!,
            model: ServerSpec.Defaults.seerEmbeddingModel)
        // The manager decides whether this tier is ever used — it prefers the
        // on-device model wherever one exists.
        MaryEmbeddings.installSeerBackend(
            seerEmbedding, model: ServerSpec.Defaults.seerEmbeddingModel)
    }

    /// Route Seer turns SSE or realtime WS. Classic client stays wired (fallback).
    /// Call at boot and from Settings — mirrors applyTTSBackend.
    package static func applySeerTransport(_ choice: SeerTransportChoice) async {
        await brain.setSeerRealtime(choice == .realtime ? seerRealtime : nil)
    }

    /// Hosted annotator over /v1/complete. Factory so mary-corpus-probe annotates
    /// the same client. Spoken turns stay on seerChat — do not reuse as voice.
    package static func makeSeerUnitAnnotator() -> SeerUnitAnnotator {
        SeerUnitAnnotator(complete: seerComplete)
    }

    /// What Seer says about each backend. Empty when it cannot be reached —
    /// the Settings row then reads "checking…" rather than inventing a state.
    package static func providerStatuses() async -> [SeerProviderStatus] {
        (try? await seerProviders.statuses()) ?? []
    }

    /// Point annotation and the Studio drafter at one backend. `applyEngine`
    /// does this for the app; the corpus probe does it on its own.
    package static func setAnnotationProvider(_ choice: LLMEngineChoice) async {
        await seerComplete.setProvider(choice)
    }

    /// The same bounded route, for Ability Studio's skill drafter. One request,
    /// one JSON answer — not a spoken turn, and not the chat lane.
    package static var studioComplete: any SeerCompleteProviding { seerComplete }

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
        // Not the learning sinks — those live in installCorpusPipeline.
    }

    /// Resets the ephemeral awareness and cancels any pending application
    /// schema flush. Durable Totem documents are cleared by the caller first.
    package static func resetAmbientMemory() async {
        AmbientContextStore.shared.clear()
        clearBehaviorEpisodeCache()
    }

    /// One-shot: previous builds wrote plaintext JSONL under this directory.
    /// Ability turns live in Totem now; leftover files must not linger.
    package static func removeLegacyBehaviorDirectory() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let directory = support
            .appendingPathComponent("Mary", isDirectory: true)
            .appendingPathComponent("behavior", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Wire or unwire voice and archive independently. stackEnabled is the
    /// Servers toggle — Lane B hosted needs the stack even when Lane A is local.
    package static func connectSeerToBrain(
        chat: Bool, archiving: Bool, stackEnabled: Bool
    ) async {
        await connectSeerVoice(enabled: chat)
        await connectTotemDepositor(enabled: archiving)
        seerStackEnabledBox.withLock { $0 = stackEnabled }
        await rewireSkillEngine(seerEnabled: stackEnabled)
        await rewireCodingAgent(seerEnabled: stackEnabled)
    }

    /// EVERY LANE RIDES SEER NOW, so "does Seer carry this" is one question:
    /// is the stack switched on. The engine choice says WHICH BACKEND Seer
    /// uses, never whether Seer is used — the parameter stays so the truth
    /// table reads the same and callers need no edit.
    package static func seerCarriesTurns(seerEnabled: Bool) -> Bool {
        seerEnabled
    }

    package static func seerCarriesTurns(
        engine: LLMEngineChoice, seerEnabled: Bool
    ) -> Bool {
        seerEnabled
    }

    package static func seerCarriesSkills(seerEnabled: Bool) -> Bool {
        seerEnabled
    }

    package static func seerCarriesSkills(
        engine: LLMEngineChoice, seerEnabled: Bool
    ) -> Bool {
        seerEnabled
    }

    /// Seed the boxes from config before the stack comes up. `bootSeerStack`
    /// reads them (connectSeerToBrain → rewire*), so they must be current
    /// BEFORE it runs, and applyEngine runs after the sign-in the on-device
    /// warm needs.
    package static func recordEngineChoices(
        voice: LLMEngineChoice, skills: LLMEngineChoice, coding: LLMEngineChoice
    ) {
        engineChoiceBox.withLock { $0 = voice }
        skillEngineChoiceBox.withLock { $0 = skills }
        codingEngineChoiceBox.withLock { $0 = coding }
    }

    /// Swap Lane B's backend without a full apply — used when the Servers
    /// toggle flips after `applyEngine` already ran.
    static func rewireSkillEngine(seerEnabled: Bool) async {
        await installSkillEngine(
            skillChoice: skillEngineChoiceBox.withLock { $0 }, seerEnabled: seerEnabled)
    }

    static func installSkillEngine(
        skillChoice: LLMEngineChoice, seerEnabled: Bool
    ) async {
        await seerSkill.setProvider(skillChoice)
        await brain.setEngine(MarySeerSkillEngine(client: seerSkill, choice: skillChoice))
    }

    /// Apply Lane A (spoken, seerChat) and Lane B (skills, /v1/skills/complete).
    /// Both ride Seer; the choices say which backend Seer uses. On-device is
    /// warmed here, so the first turn does not wait on a model load.
    package static func applyEngine(
        _ choice: LLMEngineChoice,
        skillEngine skillChoice: LLMEngineChoice = .mistral,
        seerEnabled: Bool,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String? {
        engineChoiceBox.withLock { $0 = choice }
        skillEngineChoiceBox.withLock { $0 = skillChoice }
        await connectSeerVoice(enabled: seerCarriesTurns(seerEnabled: seerEnabled))

        await seerChat.setProvider(choice)
        await seerRealtime.setProvider(choice)
        await seerComplete.setProvider(choice)
        await installSkillEngine(skillChoice: skillChoice, seerEnabled: seerEnabled)

        // Annotation is a bounded /v1/complete job either way — the backend
        // behind it follows the voice lane.
        await unitIndexer.setAnnotator(makeSeerUnitAnnotator())
        await unitIndexer.setManifestLoader { projectID in
            await totemContext.loadUnitManifest(projectID: projectID)
        }

        // THERE IS NO ENGINE WITHOUT SEER ANY MORE. On-device generation moved
        // into the server, so a stack switched off has nothing to fall back to
        // and says so instead of failing at the first turn.
        guard seerEnabled else {
            return "Chat through Seer is off in the Servers panel — no engine is available."
        }
        if choice.isOnDevice || skillChoice.isOnDevice {
            return await warmLocalProvider(progress: progress)
        }
        return nil
    }

    /// Ask Seer to load the on-device model, then follow it to ready. Returns
    /// Seer's own reason when the backend cannot serve.
    package static func warmLocalProvider(
        progress: (@Sendable (String) -> Void)? = nil,
        attempts: Int = 600
    ) async -> String? {
        do {
            try await seerProviders.warmLocal()
        } catch {
            return "On-device backend: \(error.localizedDescription)"
        }
        for _ in 0..<attempts {
            let statuses = (try? await seerProviders.statuses()) ?? []
            guard let local = statuses.first(where: { $0.choice == .local }) else {
                return "Seer did not report an on-device backend."
            }
            if local.state == "ready" { return nil }
            if let reason = local.reason, !local.available, !local.isLoading {
                return reason
            }
            if let fraction = local.progress {
                progress?("Seer is loading the on-device model (\(Int(fraction * 100))%)…")
            } else {
                progress?("Seer is loading the on-device model…")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "The on-device model did not finish loading."
    }

    /// Install or tear down the coding engine. Local still needs a Hub
    /// snapshot and Metal; hosted uses `/v1/code/complete` and skips both.
    package static func applyCodingAgent(
        enabled: Bool,
        engine: LLMEngineChoice = .mistral,
        seerEnabled: Bool = true
    ) async -> String? {
        startCodingFollowUpBridge()
        codingEnabledBox.withLock { $0 = enabled }
        codingEngineChoiceBox.withLock { $0 = engine }
        seerStackEnabledBox.withLock { $0 = seerEnabled }
        guard enabled else {
            await CodingAgentSessions.shared.install(backend: nil)
            return nil
        }
        return await installCodingBackend(engine: engine, seerEnabled: seerEnabled)
    }

    package static func seerCarriesCoding(
        engine: LLMEngineChoice, seerEnabled: Bool
    ) -> Bool {
        seerEnabled
    }

    static func rewireCodingAgent(seerEnabled: Bool) async {
        seerStackEnabledBox.withLock { $0 = seerEnabled }
        guard codingEnabledBox.withLock({ $0 }) else { return }
        _ = await installCodingBackend(
            engine: codingEngineChoiceBox.withLock { $0 }, seerEnabled: seerEnabled)
    }

    /// Coding always rides `/v1/code/complete`; the choice says which backend
    /// Seer synthesizes with. File tools still run on this Mac.
    static func installCodingBackend(
        engine: LLMEngineChoice, seerEnabled: Bool
    ) async -> String? {
        await seerCode.setProvider(engine)
        await CodingAgentSessions.shared.install(
            backend: MarySeerCodingEngine(
                client: seerCode,
                stackEnabled: { seerStackEnabledBox.withLock { $0 } }))
        guard seerEnabled else {
            return "Chat through Seer is off in the Servers panel — the coding agent needs it."
        }
        if engine.isOnDevice {
            return await warmLocalProvider()
        }
        return nil
    }

}
