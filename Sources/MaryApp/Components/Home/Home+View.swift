//
//  Home+View.swift
//  Mary
//
//  WHAT: Home session shell.
//  OUT:  Session + sheets (Settings / Debugger / Totems / Corpus / Ability Studio).
//

import MaryAmbient
import MaryBrain
import Granite
import SwiftUI
import MaryRuntime

extension Home: View {
    var view: some View {
        HomeSessionView(
            onShowSettings: {
                _state.showSettings.wrappedValue = true
            },
            onShowServers: {
                _state.showServers.wrappedValue = true
            },
            showDebugger: state.showDebugger,
            onToggleDebugger: {
                _state.showDebugger.wrappedValue.toggle()
            },
            showRouter: state.showRouter,
            onToggleRouter: {
                _state.showRouter.wrappedValue.toggle()
            },
            showTotems: state.showTotems,
            onToggleTotems: {
                _state.showTotems.wrappedValue.toggle()
            },
            showCorpus: state.showCorpus,
            onToggleCorpus: {
                _state.showCorpus.wrappedValue.toggle()
            }
        )
        .sheet(isPresented: _state.showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: _state.showServers) {
            ServersSheet()
        }
        // Light-only (Fleet). Default text/controls stay readable.
        .preferredColorScheme(.light)
    }
}

/// Reactive session page. Relays re-render on chat; `objectWillChange` feeds
/// tokens into streamVM past Granite's 200 ms @Store debounce.
struct HomeSessionView: View {
    @Environment(\.openWindow) private var openWindow
    let onShowSettings: () -> Void
    let onShowServers: () -> Void
    let showDebugger: Bool
    let onToggleDebugger: () -> Void
    let showRouter: Bool
    let onToggleRouter: () -> Void
    let showTotems: Bool
    let onToggleTotems: () -> Void
    let showCorpus: Bool
    let onToggleCorpus: () -> Void

    @Relay var chat: ChatService
    @Relay(.silence) var config: ConfigService
    /// Silenced: boot binds wake-word seams to this center. A bare `VoiceService()` is dead.
    @Relay(.silence) var voice: VoiceService

    @StateObject private var streamVM = ConversationStreamViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            // Split stays inside this VStack: root .task and streamVM .onReceive host once.
            // Bare `if` siblings keep ConversationPageView identity across pane toggles.
            HSplitView {
                ConversationPageView(
                    conversation: chat.state.conversation,
                    lastError: chat.state.lastError,
                    bootStatus: chat.state.bootStatus,
                    streamVM: streamVM,
                    // Place capsule opens the existing Routes pane; never closes it.
                    onOpenRoutes: { if !showRouter { onToggleRouter() } }
                )
                // Bar insets the conversation column only (VoiceBar owns its relays).
                .safeAreaInset(edge: .bottom) { VoiceBar(streamVM: streamVM) }
                // Divider drags cannot crush the conversation below its readable floor.
                .frame(minWidth: 396)
                .layoutPriority(1)
                if showDebugger {
                    Debugger()
                        .frame(minWidth: 300, maxWidth: 520)
                }
                if showRouter {
                    Router()
                        .frame(minWidth: 320, maxWidth: 560)
                }
                if showTotems {
                    Totems()
                        .frame(minWidth: 360, maxWidth: 600)
                }
                if showCorpus {
                    Corpus()
                        .frame(minWidth: 380, maxWidth: 640)
                }
            }
        }
        .background(Paper.page.ignoresSafeArea())
        .onReceive(_chat.relay.objectWillChange) { _ in
            streamVM.update(utterances: chat.state.conversation.utterances)
        }
        .task {
            // Wait for persisted conversation (and config) before boot.
            chat.preload()
            while !chat.isLoaded, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled else { return }
            config.preload()
            while !config.isLoaded, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled else { return }
            chat.center.boot.send()
            // History window applies to the restored page, using the restored limit.
            chat.center.setHistoryLimit.send(
                ChatService.SetHistoryLimit.Meta(limit: config.state.historyMessageLimit))
            // Detached-routine progress + follow-ups → single writer (not a streaming reducer).
            ProactiveBridge.start { kind in
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: kind))
            }
            await bootRuntime()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: .layer3) {
            MaryMark(size: 22)
            Text("Mary")
                .font(.marySerif(20, weight: .light, italic: true))
                .foregroundStyle(Paper.ink.opacity(0.85))
            Spacer()
            Button {
                onToggleDebugger()
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(showDebugger ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mary's eyes")
            Button {
                onToggleRouter()
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14))
                    .foregroundStyle(showRouter ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Routes")
            Button {
                openWindow(id: "ability-studio")
            } label: {
                Image(systemName: "shippingbox")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ability Studio")
            Button {
                onToggleTotems()
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    .foregroundStyle(showTotems ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Totems")
            Button {
                onShowServers()
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Servers")
            Button {
                onToggleCorpus()
            } label: {
                Image(systemName: "books.vertical")
                    .font(.system(size: 14))
                    .foregroundStyle(showCorpus ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Corpus")
            Button {
                onShowSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, .layer5)
        .padding(.vertical, .layer3)
        .background(Paper.page)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.maryBorder)
                .frame(height: 1)
        }
    }

    // MARK: - Boot

    private func bootRuntime() async {
        setReadiness("waking the voice…", ready: false)
        if let error = await MaryRuntime.bootKokoro(voice: config.state.voice) {
            // Kokoro gates boot only when it is the speaker. Hosted TTS continues.
            guard config.state.ttsBackend == .kokoro else {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: .error(
                    "\(error) \(config.state.ttsBackend.displayName) still speaks; only the "
                    + "on-device cover voice is unavailable.")))
                return await bootRuntimeAfterVoice()
            }
            setReadiness(error, ready: false)
            return
        }
        // Align Settings picker with the voice the bundle actually loaded.
        if let loaded = MaryRuntime.activeKokoroVoice, loaded != config.state.voice {
            config.center.update.send(ConfigService.Update.Meta(voice: loaded))
        }
        await bootRuntimeAfterVoice()
    }

    /// Brain, ambient, Seer, speaker — after voice. Hosted TTS skips Kokoro and still boots.
    private func bootRuntimeAfterVoice() async {

        let engine = config.state.llmEngine
        let skillEngine = config.state.skillEngine
        let warmingStatus: String
        switch (engine, skillEngine) {
        case (.local, .local):
            warmingStatus = "warming the on-device model (first run downloads ~4 GB)…"
        case (.hosted, .local):
            warmingStatus =
                "checking the Seer server, warming the on-device model for skills (first run downloads ~4 GB)…"
        case (_, .hosted):
            warmingStatus = "checking the Seer server for voice and skill synthesis…"
        }
        setReadiness(warmingStatus, ready: false)
        if let error = await MaryRuntime.applyEngine(
            engine,
            skillEngine: skillEngine,
            localModelID: config.state.localModelID,
            seerEnabled: config.state.seerEnabled
        ) {
            setReadiness(error, ready: false)
            return
        }
        if config.state.codingAgentEnabled {
            setReadiness("warming the on-device coding model…", ready: false)
            if let error = await MaryRuntime.applyCodingAgent(
                enabled: true,
                engine: config.state.codingEngine,
                modelID: config.state.codingAgentModelID,
                seerEnabled: config.state.seerEnabled)
            {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                    kind: .error("Coding agent: \(error)")))
            }
        } else {
            _ = await MaryRuntime.applyCodingAgent(
                enabled: false,
                engine: config.state.codingEngine,
                modelID: config.state.codingAgentModelID,
                seerEnabled: config.state.seerEnabled)
        }

        // Workspace focus observer: app boot only (probes stay poll-fed).
        WorkspaceFocusObserver.installOnce()
        MaryRuntime.removeLegacyBehaviorDirectory()
        await MaryRuntime.installBrainConfiguration(
            projects: config.state.projectsByName)
        MaryRuntime.applySkillRunTimeout(config.state.skillRunTimeoutSeconds)
        await MaryRuntime.brain.setHistoryLimit(config.state.historyMessageLimit)
        await MaryRuntime.applyPronunciations(config.state.pronunciationsByWord)
        MaryRuntime.styleSelection = config.state.speechStyle
        await MaryRuntime.speaker.setStyle(config.state.speechStyle.style)
        // Seer stack before TTS: default backend is Seer /v1/speak (needs sign-in).
        await bootSeerStack()
        // Per-chunk voice degrade → chat mirror. Hook is off-actor; hop to MainActor.
        MaryRuntime.onVoiceDegrade = { note in
            Task { @MainActor in
                // Fresh relay onto the online center (hook cannot capture this view's).
                ChatService().center.mirrorVoice.send(
                    ChatService.MirrorVoice.Meta(kind: .error(note)))
            }
        }
        // Synthesis failed past retry/fallback: skipped sentence, never silent.
        Task.detached {
            for await event in await MaryRuntime.speaker.events() {
                guard case .chunkFailed(let text, let reason) = event else { continue }
                let note = "A line was skipped (\(reason)): \u{201C}\(text.prefix(80))\u{201D}"
                await MainActor.run {
                    ChatService().center.mirrorVoice.send(
                        ChatService.MirrorVoice.Meta(kind: .error(note)))
                }
            }
        }
        if let notice = await MaryRuntime.applyTTSBackend(
            config.state.ttsBackend, hostedVoice: config.state.seerVoice) {
            chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: .error(notice)))
        }
        setReadiness(nil, ready: true)
        // "Hey Mary" arms only once the app can answer. Bind online relays first.
        MaryRuntime.wakeSessionStart = { voice.center.start.send() }
        MaryRuntime.wakeVADSource = { config.state.vad }
        MaryRuntime.applyWakeWord(config.state.wakeWordEnabled)
        // First arm opens an audio engine; boot must not hang if it wedges.
        Task { await MaryRuntime.wakeStandby.noteAppReady() }
    }

    /// Seer/Totem after engine so chat still works if the stack fails. Failures mirror and continue.
    private func bootSeerStack() async {
        // Totem node UUID is DB identity: adopt or mint, then pin in config.
        var nodeID = config.state.totemNodeID
        if UUID(uuidString: nodeID) == nil {
            nodeID = TotemNodeIdentity.adoptOrMint(configured: "")
            config.center.update.send(ConfigService.Update.Meta(totemNodeID: nodeID))
        }
        MaryRuntime.applyCorpusIndexing(enabled: config.state.ambientCorpusIndexing)
        await MaryRuntime.applyServers(config: config.state, nodeID: nodeID)

        guard config.state.seerEnabled else {
            await MaryRuntime.connectSeerToBrain(
                chat: false, archiving: false, stackEnabled: false)
            return
        }

        if config.state.autoStartServers {
            setReadiness("starting Seer and Totem…", ready: false)
            if let failure = await MaryRuntime.localStack.ensureRunning() {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                    kind: .error("Local servers: \(failure) Chat continues without Seer.")))
            } else if config.state.totemGraphPolicyManaged {
                // Best-effort ontology + co-mention edges; refusal never blocks boot.
                _ = await TotemGraphPolicy.push(totemPort: config.state.totemPort)
            }
        }

        setReadiness("signing in to Seer…", ready: false)
        if let error = await MaryRuntime.applySeerAccount(
            email: config.state.seerEmail,
            password: config.state.seerPassword,
            seerPort: config.state.seerPort) {
            chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                kind: .error("\(error) Chat continues without Seer.")))
            await MaryRuntime.connectSeerToBrain(
                chat: false, archiving: false, stackEnabled: false)
            return
        }
        // Sign-in succeeded → Totem deposits regardless of Voice (Lane A) engine.
        await MaryRuntime.connectSeerToBrain(
            chat: MaryRuntime.seerCarriesTurns(seerEnabled: true),
            archiving: true,
            stackEnabled: true)
        // Transport uses the signed-in session; apply last.
        await MaryRuntime.applySeerTransport(config.state.seerTransport)
    }

    private func setReadiness(_ status: String?, ready: Bool) {
        chat.center.setReadiness.send(
            ChatService.SetReadiness.Meta(status: status, ready: ready)
        )
    }
}

// MARK: - Voice bar

/// Voice bar owns its relay boundary. `audioLevel` ticks ~60×/s; an un-silenced
/// `@Relay` on HomeSessionView re-rendered ConversationPageView (brushstroke flicker).
/// Reads/sends stay on this view.
private struct VoiceBar: View {
    @ObservedObject var streamVM: ConversationStreamViewModel

    @Relay var voice: VoiceService
    @Relay var chat: ChatService
    /// Un-silenced: this view already re-renders at meter rate. Silencing would freeze the ear glyph.
    @Relay var config: ConfigService

    /// Composer stays quiet until generation and the char-by-char reveal settle.
    private var isBusy: Bool {
        chat.state.isGenerating || streamVM.phase != .idle
    }

    var body: some View {
        VoiceStatusBar(
            isSessionActive: voice.state.isSessionActive,
            phase: voice.state.phase,
            audioLevel: voice.state.audioLevel,
            partialTranscript: voice.state.lastPartial,
            isMicEnabled: chat.state.isReady,
            isSendEnabled: chat.state.isReady && !isBusy && !voice.state.isSessionActive,
            runningRoutines: chat.state.runningRoutineRows,
            isStandingBy: config.state.wakeWordEnabled
                && chat.state.isReady
                && !voice.state.isSessionActive,
            onMicToggle: {
                if voice.state.isSessionActive {
                    voice.center.stop.send()
                } else {
                    guard MaryRuntime.admitVoiceStart() else { return }
                    voice.center.start.send()
                }
            },
            onSend: { text in
                // Typed turns outside Granite streaming reducers (snapshot-republish races).
                Task {
                    await TextTurnRunner.shared.submit(text) { kind in
                        chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: kind))
                    }
                }
            }
        )
    }
}
