//
//  Home+View.swift
//  Mary
//
//  WHAT: Home session shell.
//  OUT:  Session + sheets (Settings / Debugger / Threads / Corpus / Ability Studio).
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
            openPanes: _state.openPanes
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
    @Environment(\.maryWindowSize) private var windowSize
    let onShowSettings: () -> Void
    let onShowServers: () -> Void
    @Binding var openPanes: [Home.Pane]

    /// The panes the current width has room for. Order is the user's
    /// intent; a pane past the budget folds away rather than clipping the
    /// conversation or crowding the ones already shown.
    private var visiblePanes: Set<Home.Pane> {
        HomePaneBudget.visible(open: openPanes, width: windowSize.width)
    }

    /// Off → append (open it). Visible → remove (close it). Open but
    /// folded → move to the end, so the budget picks it up first. Snapshots
    /// both checks before mutating — `visiblePanes` is computed from
    /// `openPanes`, so reading it again after the first `removeAll` would
    /// answer a question that has already changed underneath it.
    private func tapPane(_ pane: Home.Pane) {
        let wasVisible = visiblePanes.contains(pane)
        let wasOpen = openPanes.contains(pane)
        if wasOpen {
            openPanes.removeAll { $0 == pane }
        }
        if !wasVisible {
            openPanes.append(pane)
        }
    }

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
                    onOpenRoutes: { if !visiblePanes.contains(.router) { tapPane(.router) } }
                )
                // Bar insets the conversation column only (VoiceBar owns its relays).
                .safeAreaInset(edge: .bottom) { VoiceBar(streamVM: streamVM) }
                // Divider drags cannot crush the conversation below its readable floor.
                .maryColumn(Paper.Layout.conversation)
                .layoutPriority(1)
                if visiblePanes.contains(.debugger) {
                    Debugger()
                        .maryColumn(Paper.Layout.sidePane)
                }
                if visiblePanes.contains(.router) {
                    Router()
                        .maryColumn(Paper.Layout.sidePane)
                }
                if visiblePanes.contains(.threads) {
                    Threads()
                        .maryColumn(Paper.Layout.sidePane)
                }
                if visiblePanes.contains(.corpus) {
                    Corpus()
                        .maryColumn(Paper.Layout.sidePane)
                }
            }
        }
        .background(Paper.page.ignoresSafeArea())
        .onReceive(_chat.relay.objectWillChange) { _ in
            streamVM.update(utterances: chat.state.conversation.utterances)
        }
        .task {
            #if DEBUG
            MaryLayoutCheck.pinHome()
            if let directive = MaryLayoutCheck.directive {
                if !directive.panes.isEmpty {
                    openPanes = directive.panes.compactMap(Home.Pane.init(rawValue:))
                }
                if directive.studioSize != nil {
                    openWindow(id: "ability-studio")
                }
                if MaryLayoutCheck.opens(sheet: "settings") { onShowSettings() }
            }
            #endif
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
            paneButton(.debugger, symbol: "eye", label: "Mary's eyes")
            paneButton(.router, symbol: "arrow.triangle.branch", label: "Routes")
            Button {
                openWindow(id: "ability-studio")
            } label: {
                Image(systemName: "shippingbox")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ability Studio")
            paneButton(.threads, symbol: "point.3.connected.trianglepath.dotted", label: "Threads")
            Button {
                onShowServers()
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Servers")
            paneButton(.corpus, symbol: "books.vertical", label: "Corpus")
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

    /// Off (0.7) → visible (full ink) → folded (0.45). A folded pane is
    /// still open — the window is just not wide enough to show it — so the
    /// dimmed tint reads as "waiting," not "off."
    private func paneButton(_ pane: Home.Pane, symbol: String, label: String) -> some View {
        let isVisible = visiblePanes.contains(pane)
        let isFolded = !isVisible && openPanes.contains(pane)
        return Button {
            tapPane(pane)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(
                    isVisible ? Paper.ink
                    : isFolded ? Paper.ink.opacity(0.45)
                    : Paper.ink.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(isFolded ? "Open, but folded — widen the window" : label)
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

    /// Brain, ambient, Sewn, speaker — after voice. Hosted TTS skips Kokoro and still boots.
    private func bootRuntimeAfterVoice() async {

        let engine = config.state.llmEngine
        let skillEngine = config.state.skillEngine
        let coding = config.state.codingEngine
        // THE BOXES BEFORE THE STACK. `bootSewnStack` reads them (through
        // connectSewnToBrain's rewire), and the on-device warm below needs the
        // sign-in that same call performs — so the order is: record, connect,
        // then apply.
        MaryRuntime.recordEngineChoices(
            voice: engine, skills: skillEngine, coding: coding)
        setReadiness("checking the Sewn server…", ready: false)
        await bootSewnStack()

        let onDevice = engine.isOnDevice || skillEngine.isOnDevice
        setReadiness(
            onDevice
                ? "warming Sewn's on-device model (first run downloads ~4 GB)…"
                : "checking the Sewn server for voice and skill synthesis…",
            ready: false)
        if let error = await MaryRuntime.applyEngine(
            engine,
            skillEngine: skillEngine,
            sewnEnabled: config.state.sewnEnabled,
            progress: { status in
                Task { @MainActor in setReadiness(status, ready: false) }
            }
        ) {
            setReadiness(error, ready: false)
            return
        }
        if config.state.codingAgentEnabled {
            setReadiness("preparing the coding agent…", ready: false)
            if let error = await MaryRuntime.applyCodingAgent(
                enabled: true,
                engine: coding,
                sewnEnabled: config.state.sewnEnabled)
            {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                    kind: .error("Coding agent: \(error)")))
            }
        } else {
            _ = await MaryRuntime.applyCodingAgent(
                enabled: false,
                engine: coding,
                sewnEnabled: config.state.sewnEnabled)
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
        // The Sewn stack came up before the engines — see bootRuntimeAfterVoice.
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
            config.state.ttsBackend, hostedVoice: config.state.sewnVoice) {
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

    /// Sewn/Thread after engine so chat still works if the stack fails. Failures mirror and continue.
    private func bootSewnStack() async {
        // Thread node UUID is DB identity: adopt or mint, then pin in config.
        var nodeID = config.state.threadNodeID
        if UUID(uuidString: nodeID) == nil {
            nodeID = ThreadNodeIdentity.adoptOrMint(configured: "")
            config.center.update.send(ConfigService.Update.Meta(threadNodeID: nodeID))
        }
        MaryRuntime.applyCorpusIndexing(enabled: config.state.ambientCorpusIndexing)
        await MaryRuntime.applyServers(config: config.state, nodeID: nodeID)

        guard config.state.sewnEnabled else {
            await MaryRuntime.connectSewnToBrain(
                chat: false, archiving: false, stackEnabled: false)
            return
        }

        if config.state.autoStartServers {
            setReadiness("starting Sewn and Thread…", ready: false)
            if let failure = await MaryRuntime.localStack.ensureRunning() {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                    kind: .error("Local servers: \(failure) Chat continues without Sewn.")))
            } else if config.state.threadGraphPolicyManaged {
                // Best-effort ontology + co-mention edges; refusal never blocks boot.
                _ = await ThreadGraphPolicy.push(threadPort: config.state.threadPort)
            }
        }

        setReadiness("signing in to Sewn…", ready: false)
        if let error = await MaryRuntime.applySewnAccount(
            email: config.state.sewnEmail,
            password: config.state.sewnPassword,
            sewnPort: config.state.sewnPort) {
            chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                kind: .error("\(error) Chat continues without Sewn.")))
            await MaryRuntime.connectSewnToBrain(
                chat: false, archiving: false, stackEnabled: false)
            return
        }
        // Sign-in succeeded → Thread deposits regardless of Voice (Lane A) engine.
        await MaryRuntime.connectSewnToBrain(
            chat: MaryRuntime.sewnCarriesTurns(sewnEnabled: true),
            archiving: true,
            stackEnabled: true)
        // Transport uses the signed-in session; apply last.
        await MaryRuntime.applySewnTransport(config.state.sewnTransport)
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
