//
//  MaryRuntime+Stack.swift
//  MaryRuntime
//
//  WHAT: Sewn/Thread stack appliers, spoken register, coding-engine install.
//  IN:   Settings / Servers sheet / applyEngine
//  OUT:  sewnChat / sewnRealtime / threadContext / InferenceEngine
//  PIN:  threadArchivingEnabledBox lives in +FocusSetup (internal for file split).
//

import MaryBrain
import MaryPlugin
import MaryThread
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

    // MARK: - Sewn/Thread stack appliers

    /// Point stack at configured checkouts/ports. Running servers keep running.
    /// threadGRPCPort — read by makeThreadReader.
    nonisolated(unsafe) private(set) static var threadGRPCPort = ServerSpec.Defaults.threadGRPCPort
    nonisolated(unsafe) private(set) static var fleetGRPCPort = ServerSpec.Defaults.fleetGRPCPort

    /// A fresh read client for inspector/library queries (connections are
    /// per-call, so clients are cheap to make at the current port).
    package static func makeThreadReader() -> ThreadDirectClient {
        ThreadDirectClient(port: threadGRPCPort)
    }

    package static func makeFleetClient() -> FleetDirectClient {
        FleetDirectClient(port: fleetGRPCPort)
    }

    /// Point the Fleet dial at a node without booting the server stack —
    /// what `mary-life-probe` needs, and nothing else it does not.
    /// PIN: Lives here because `fleetGRPCPort`'s setter is file-private.
    package static func configureLifeAccess(nodeID: String, fleetGRPCPort port: Int) {
        fleetGRPCPort = port
        threadNodeIDBox.withLock { $0 = nodeID }
    }

    package static func applyServers(config: ConfigService.Center.State, nodeID: String) async {
        threadGRPCPort = config.threadGRPCPort
        fleetGRPCPort = config.fleetGRPCPort
        threadNodeIDBox.withLock { $0 = nodeID }
        lifeModeBox.withLock { $0 = config.lifeMode }
        await lifeEngine.setActsOnTurns(
            Set(config.lifeTurnDisciplines.map(AbilityID.init)))
        await lifeEngine.setMode(config.lifeMode)
        ensureDataDirectories([config.sewnDataDir, config.threadDataDir, config.fleetDataDir])
        await localStack.configure([
            .sewn(
                checkoutPath: config.sewnCheckoutPath,
                port: config.sewnPort,
                grpcPort: config.sewnGRPCPort,
                dataDir: config.sewnDataDir),
            .thread(
                checkoutPath: config.threadCheckoutPath,
                port: config.threadPort,
                grpcPort: config.threadGRPCPort,
                mothershipGRPCPort: config.sewnGRPCPort,
                nodeID: nodeID,
                graphBackend: config.threadGraphBackend,
                dataDir: config.threadDataDir),
            .fleet(
                checkoutPath: config.fleetCheckoutPath,
                port: config.fleetPort,
                grpcPort: config.fleetGRPCPort,
                threadGRPCPort: config.threadGRPCPort,
                dataDir: config.fleetDataDir),
        ])
        await threadContext.configure(port: config.threadGRPCPort)
        // Both transports get the same scope closure — they wrap the same ChatRequest.
        await sewnChat.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!,
            personalThreadID: nodeID,
            chatModel: config.sewnChatModel,
            retrievalScope: { retrievalScope(ownerID: $0) })
        await sewnRealtime.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!,
            personalThreadID: nodeID,
            chatModel: config.sewnChatModel,
            voiceID: "\(config.sewnVoice)_neutral",
            retrievalScope: { retrievalScope(ownerID: $0) })
        await sewnTTS.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnVision.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnComplete.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnSkill.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnCode.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnThreads.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnProviders.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!)
        await sewnEmbedding.configure(
            baseURL: URL(string: "http://127.0.0.1:\(config.sewnPort)")!,
            model: ServerSpec.Defaults.sewnEmbeddingModel)
        // The manager decides whether this tier is ever used — it prefers the
        // on-device model wherever one exists.
        MaryEmbeddings.installSewnBackend(
            sewnEmbedding, model: ServerSpec.Defaults.sewnEmbeddingModel)
    }

    /// Route Sewn turns SSE or realtime WS. Classic client stays wired (fallback).
    /// Call at boot and from Settings — mirrors applyTTSBackend.
    package static func applySewnTransport(_ choice: SewnTransportChoice) async {
        await brain.setSewnRealtime(choice == .realtime ? sewnRealtime : nil)
    }

    /// Hosted annotator over /v1/complete. Factory so mary-corpus-probe annotates
    /// the same client. Spoken turns stay on sewnChat — do not reuse as voice.
    package static func makeSewnUnitAnnotator() -> SewnUnitAnnotator {
        SewnUnitAnnotator(complete: sewnComplete)
    }

    /// What Sewn says about each backend. Empty when it cannot be reached —
    /// the Settings row then reads "checking…" rather than inventing a state.
    package static func providerStatuses() async -> [SewnProviderStatus] {
        (try? await sewnProviders.statuses()) ?? []
    }

    /// Point annotation and the Studio drafter at one backend. `applyEngine`
    /// does this for the app; the corpus probe does it on its own.
    package static func setAnnotationProvider(_ choice: LLMEngineChoice) async {
        await sewnComplete.setProvider(choice)
    }

    /// The same bounded route, for Ability Studio's skill drafter. One request,
    /// one JSON answer — not a spoken turn, and not the chat lane.
    package static var studioComplete: any SewnCompleteProviding { sewnComplete }

    /// Sign in with the configured account. Returns error text or nil.
    package static func applySewnAccount(email: String, password: String, sewnPort: Int) async -> String? {
        await sewnSession.configure(
            baseURL: URL(string: "http://127.0.0.1:\(sewnPort)")!,
            email: email,
            password: password)
        return await sewnSession.signIn()
    }

    /// Wire (or unwire) Sewn as the brain's VOICE.
    static func connectSewnVoice(enabled: Bool) async {
        await brain.setSewnChat(enabled ? sewnChat : nil)
    }

    /// Wire (or unwire) Thread as the brain's ARCHIVE.
    static func connectThreadDepositor(enabled: Bool) async {
        threadArchivingEnabledBox.withLock { $0 = enabled }
        await brain.setDepositor(enabled ? threadContext : nil)
        // Not the learning sinks — those live in installCorpusPipeline.
    }

    /// Resets the ephemeral awareness and cancels any pending application
    /// schema flush. Durable Thread documents are cleared by the caller first.
    package static func resetAmbientMemory() async {
        AmbientContextStore.shared.clear()
        clearBehaviorEpisodeCache()
    }

    /// One-shot: previous builds wrote plaintext JSONL under this directory.
    /// Ability turns live in Thread now; leftover files must not linger.
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
    package static func connectSewnToBrain(
        chat: Bool, archiving: Bool, stackEnabled: Bool
    ) async {
        await connectSewnVoice(enabled: chat)
        await connectThreadDepositor(enabled: archiving)
        sewnStackEnabledBox.withLock { $0 = stackEnabled }
        await rewireSkillEngine(sewnEnabled: stackEnabled)
        await rewireCodingAgent(sewnEnabled: stackEnabled)
    }

    /// EVERY LANE RIDES SEWN NOW, so "does Sewn carry this" is one question:
    /// is the stack switched on. The engine choice says WHICH BACKEND Sewn
    /// uses, never whether Sewn is used — the parameter stays so the truth
    /// table reads the same and callers need no edit.
    package static func sewnCarriesTurns(sewnEnabled: Bool) -> Bool {
        sewnEnabled
    }

    package static func sewnCarriesTurns(
        engine: LLMEngineChoice, sewnEnabled: Bool
    ) -> Bool {
        sewnEnabled
    }

    package static func sewnCarriesSkills(sewnEnabled: Bool) -> Bool {
        sewnEnabled
    }

    package static func sewnCarriesSkills(
        engine: LLMEngineChoice, sewnEnabled: Bool
    ) -> Bool {
        sewnEnabled
    }

    /// Seed the boxes from config before the stack comes up. `bootSewnStack`
    /// reads them (connectSewnToBrain → rewire*), so they must be current
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
    static func rewireSkillEngine(sewnEnabled: Bool) async {
        await installSkillEngine(
            skillChoice: skillEngineChoiceBox.withLock { $0 }, sewnEnabled: sewnEnabled)
    }

    static func installSkillEngine(
        skillChoice: LLMEngineChoice, sewnEnabled: Bool
    ) async {
        await sewnSkill.setProvider(skillChoice)
        await brain.setEngine(MarySewnSkillEngine(client: sewnSkill, choice: skillChoice))
    }

    /// Apply Lane A (spoken, sewnChat) and Lane B (skills, /v1/skills/complete).
    /// Both ride Sewn; the choices say which backend Sewn uses. On-device is
    /// warmed here, so the first turn does not wait on a model load.
    package static func applyEngine(
        _ choice: LLMEngineChoice,
        skillEngine skillChoice: LLMEngineChoice = .mistral,
        sewnEnabled: Bool,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String? {
        engineChoiceBox.withLock { $0 = choice }
        skillEngineChoiceBox.withLock { $0 = skillChoice }
        await connectSewnVoice(enabled: sewnCarriesTurns(sewnEnabled: sewnEnabled))

        await sewnChat.setProvider(choice)
        await sewnRealtime.setProvider(choice)
        await sewnComplete.setProvider(choice)
        await installSkillEngine(skillChoice: skillChoice, sewnEnabled: sewnEnabled)

        // Annotation is a bounded /v1/complete job either way — the backend
        // behind it follows the voice lane.
        await unitIndexer.setAnnotator(makeSewnUnitAnnotator())
        await unitIndexer.setManifestLoader { projectID in
            await threadContext.loadUnitManifest(projectID: projectID)
        }

        // THERE IS NO ENGINE WITHOUT SEWN ANY MORE. On-device generation moved
        // into the server, so a stack switched off has nothing to fall back to
        // and says so instead of failing at the first turn.
        guard sewnEnabled else {
            return "Chat through Sewn is off in the Servers panel — no engine is available."
        }
        if choice.isOnDevice || skillChoice.isOnDevice {
            return await warmLocalProvider(progress: progress)
        }
        return nil
    }

    /// Ask Sewn to load the on-device model, then follow it to ready. Returns
    /// Sewn's own reason when the backend cannot serve.
    package static func warmLocalProvider(
        progress: (@Sendable (String) -> Void)? = nil,
        attempts: Int = 600
    ) async -> String? {
        do {
            try await sewnProviders.warmLocal()
        } catch {
            return "On-device backend: \(error.localizedDescription)"
        }
        for _ in 0..<attempts {
            let statuses = (try? await sewnProviders.statuses()) ?? []
            guard let local = statuses.first(where: { $0.choice == .local }) else {
                return "Sewn did not report an on-device backend."
            }
            if local.state == "ready" { return nil }
            if let reason = local.reason, !local.available, !local.isLoading {
                return reason
            }
            if let fraction = local.progress {
                progress?("Sewn is loading the on-device model (\(Int(fraction * 100))%)…")
            } else {
                progress?("Sewn is loading the on-device model…")
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
        sewnEnabled: Bool = true
    ) async -> String? {
        startCodingFollowUpBridge()
        codingEnabledBox.withLock { $0 = enabled }
        codingEngineChoiceBox.withLock { $0 = engine }
        sewnStackEnabledBox.withLock { $0 = sewnEnabled }
        guard enabled else {
            await CodingAgentSessions.shared.install(backend: nil)
            return nil
        }
        return await installCodingBackend(engine: engine, sewnEnabled: sewnEnabled)
    }

    package static func sewnCarriesCoding(
        engine: LLMEngineChoice, sewnEnabled: Bool
    ) -> Bool {
        sewnEnabled
    }

    static func rewireCodingAgent(sewnEnabled: Bool) async {
        sewnStackEnabledBox.withLock { $0 = sewnEnabled }
        guard codingEnabledBox.withLock({ $0 }) else { return }
        _ = await installCodingBackend(
            engine: codingEngineChoiceBox.withLock { $0 }, sewnEnabled: sewnEnabled)
    }

    /// Coding always rides `/v1/code/complete`; the choice says which backend
    /// Sewn synthesizes with. File tools still run on this Mac.
    static func installCodingBackend(
        engine: LLMEngineChoice, sewnEnabled: Bool
    ) async -> String? {
        await sewnCode.setProvider(engine)
        await CodingAgentSessions.shared.install(
            backend: MarySewnCodingEngine(
                client: sewnCode,
                stackEnabled: { sewnStackEnabledBox.withLock { $0 } }))
        guard sewnEnabled else {
            return "Chat through Sewn is off in the Servers panel — the coding agent needs it."
        }
        if engine.isOnDevice {
            return await warmLocalProvider()
        }
        return nil
    }

}
