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
            onShowAbilityRuns: {
                _state.showAbilityRuns.wrappedValue = true
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
        .sheet(isPresented: _state.showAbilityRuns) {
            AbilityExecutionLogSheet()
        }
        // Palette is light-only (Fleet's rule); lock it so default
        // text/controls stay readable.
        .preferredColorScheme(.light)
    }
}

/// The reactive half of the page (Gita's StorySessionView pattern): a plain
/// view whose un-silenced relay re-renders on chat changes, while the raw
/// `relay.objectWillChange` bridge feeds per-token updates into the display-
/// tempo view model, past Granite's 200 ms @Store debounce.
struct HomeSessionView: View {
    @Environment(\.openWindow) private var openWindow
    let onShowSettings: () -> Void
    let onShowAbilityRuns: () -> Void
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
    /// Silenced: held ONLY so boot can bind the wake-word seams to the one
    /// online center — a bare `VoiceService()` builds a private center whose
    /// sends reach nothing.
    @Relay(.silence) var voice: VoiceService

    @StateObject private var streamVM = ConversationStreamViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            // SINGLE-BOOT INVARIANT: the split lives INSIDE this VStack so
            // the root-attached .task (boot.send / ProactiveBridge.start /
            // bootRuntime — must fire exactly once) and the .onReceive
            // streamVM bridge (one subscription) never re-host when the pane
            // toggles. The conditional SECOND child (not an if/else around
            // the whole split) keeps ConversationPageView's structural
            // identity — scroll position, list state, and the voice
            // bar's unsent draft all survive every toggle, because the bar
            // now hangs off that column rather than the window.
            HSplitView {
                ConversationPageView(
                    conversation: chat.state.conversation,
                    lastError: chat.state.lastError,
                    bootStatus: chat.state.bootStatus,
                    streamVM: streamVM,
                    // The place capsule's tap-through: the EXISTING header
                    // affordance, opened (never closed) — no new navigation.
                    onOpenRoutes: { if !showRouter { onToggleRouter() } }
                )
                // The bar belongs to the CONVERSATION column, not the
                // window: as a root inset it stretched under the debugger
                // pane too, reserving dead space beneath a minimap that has
                // nothing to say to it. Scoped here it insets only the page
                // it composes with. The bar carries its own relays now (see
                // VoiceBar) — this is only where it hangs.
                .safeAreaInset(edge: .bottom) { VoiceBar(streamVM: streamVM) }
                // layoutPriority keeps divider drags from crushing the
                // conversation below its readable floor.
                .frame(minWidth: 396)
                .layoutPriority(1)
                if showDebugger {
                    Debugger()
                        .frame(minWidth: 300, maxWidth: 520)
                }
                // A THIRD bare `if`, never an if/else chain, for the same
                // reason the second one is bare: ConversationPageView must
                // stay the unconditional FIRST child so its structural
                // identity — scroll position, list state, the voice
                // bar's unsent draft — survives every toggle. With both panes
                // open the window's floor is 396 + 300 + 320 ≈ 1016 pt.
                if showRouter {
                    Router()
                        .frame(minWidth: 320, maxWidth: 560)
                }
                // A FOURTH bare `if`, for the reason the two above give: the
                // conversation must stay the unconditional FIRST child so its
                // structural identity survives every toggle. With all four
                // open the window's floor is 396 + 300 + 320 + 340 ≈ 1356 pt.
                // A FIFTH bare `if`, for the reason the three above give: the
                // conversation must stay the unconditional FIRST child so its
                // structural identity survives every toggle. With all five
                // open the window's floor is 396 + 300 + 320 + 340 + 360 ≈ 1716 pt.
                if showTotems {
                    Totems()
                        .frame(minWidth: 360, maxWidth: 600)
                }
                // A SIXTH bare `if`, for the reason the four above give.
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
            // The persisted conversation restores asynchronously; booting
            // against the pre-restore default would sanitize an empty page.
            // Wait for the store, then boot (Gita's rule).
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
            // The window applies to the restored page too, not just to
            // turns taken from here on — a transcript that grew unbounded
            // under an older build collapses on this launch. Sent after
            // config has restored (the wait above), so it carries the
            // user's real limit rather than the struct default.
            chat.center.setHistoryLimit.send(
                ChatService.SetHistoryLimit.Meta(limit: config.state.historyMessageLimit))
            // Long-lived subscriber: detached-routine progress + follow-ups,
            // forwarded into the single writer (never a streaming reducer —
            // its boot-era snapshot was the history-rollback bug).
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
                    // A toggle, not a sheet — the active tint is the only
                    // deviation from the header-button trio.
                    .foregroundStyle(showDebugger ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mary's eyes")
            Button {
                onToggleRouter()
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14))
                    // A toggle like the eye beside it, and tinted the same
                    // way — the two panes are read together.
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
                onShowAbilityRuns()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ability runs")
            Button {
                onToggleTotems()
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    // A toggle like the three before it, tinted the same way.
                    // The server rack this glyph replaced now opens from
                    // inside the pane's header.
                    .foregroundStyle(showTotems ? Paper.ink : Paper.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Totems")
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
            // THE ON-DEVICE ENGINE IS THE GATE ONLY WHEN IT IS THE SPEAKER.
            // Seer renders its own audio server-side; Kokoro sits behind it as
            // the per-chunk cover. Returning here parked the whole session
            // before readiness — no chat, no engine, no Seer — over a voice
            // that session never speaks with.
            guard config.state.ttsBackend == .kokoro else {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: .error(
                    "\(error) \(config.state.ttsBackend.displayName) still speaks; only the "
                    + "on-device cover voice is unavailable.")))
                return await bootRuntimeAfterVoice()
            }
            setReadiness(error, ready: false)
            return
        }
        // Heal a config that named a voice the bundle does not carry, so the
        // Settings picker agrees with the speaker.
        if let loaded = MaryRuntime.activeKokoroVoice, loaded != config.state.voice {
            config.center.update.send(ConfigService.Update.Meta(voice: loaded))
        }
        await bootRuntimeAfterVoice()
    }

    /// Everything after the voice: the brain engine, ambient wiring, the Seer
    /// stack and the speaker. Split out so a hosted-TTS session can skip the
    /// on-device voice and still boot the whole runtime.
    private func bootRuntimeAfterVoice() async {

        let engine = config.state.llmEngine
        let warmingStatus: String
        switch engine {
        // THE ON-DEVICE MODEL WARMS IN BOTH MODES, so both messages say so.
        // Hosted moves the SPOKEN pass to the server; the acting pass and the
        // unreachable-server fallback are still the local engine, and a
        // "checking the Seer server…" that quietly downloaded 4 GB was a
        // status line describing the smaller half of what was happening.
        case .local: warmingStatus = "warming the on-device model (first run downloads ~4 GB)…"
        case .hosted: warmingStatus =
            "checking the Seer server, warming the on-device model for acting (first run downloads ~4 GB)…"
        }
        setReadiness(warmingStatus, ready: false)
        if let error = await MaryRuntime.applyEngine(
            engine,
            localModelID: config.state.localModelID,
            seerEnabled: config.state.seerEnabled
        ) {
            setReadiness(error, ready: false)
            return
        }

        // Instant coding/writing focus transitions — app boot only, never
        // installBrainConfiguration (probes call that; headless stays
        // poll-fed and deterministic).
        WorkspaceFocusObserver.installOnce()
        await MaryRuntime.installBrainConfiguration(
            projects: config.state.projectsByName)
        // THE RECORDING SWITCH, applied at boot so the first turn of the
        // session obeys the setting rather than the default.
        MaryRuntime.behavioralRecordingEnabledBox.withLock {
            $0 = config.state.behavioralRecording
        }
        await MaryRuntime.brain.setHistoryLimit(config.state.historyMessageLimit)
        await MaryRuntime.applyPronunciations(config.state.pronunciationsByWord)
        MaryRuntime.styleSelection = config.state.speechStyle
        await MaryRuntime.speaker.setStyle(config.state.speechStyle.style)
        // Seer stack first: the default TTS backend is Seer's /v1/speak,
        // which needs the sign-in that happens in here.
        await bootSeerStack()
        // Per-chunk voice degradation surfaces once per session through the
        // same mirror the apply notices use. The hook fires off-actor, so it
        // hops home before touching the chat center.
        MaryRuntime.onVoiceDegrade = { note in
            Task { @MainActor in
                // A fresh relay handle onto the one online center — the hook
                // fires off-actor and cannot capture the view's own.
                ChatService().center.mirrorVoice.send(
                    ChatService.MirrorVoice.Meta(kind: .error(note)))
            }
        }
        // A chunk whose synthesis failed PAST every retry and fallback is a
        // skipped sentence — it must never vanish without a trace.
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
        // "Hey Mary" standby arms only once the app can actually answer a
        // wake — a session started against a half-booted runtime would greet
        // and then stall. The seams bind the ONLINE relays (captured through
        // this view's @Relay handles) before the first wake can fire.
        MaryRuntime.wakeSessionStart = { voice.center.start.send() }
        MaryRuntime.wakeVADSource = { config.state.vad }
        MaryRuntime.applyWakeWord(config.state.wakeWordEnabled)
        // Fire-and-forget: the first arm opens an audio engine, and boot must
        // not hang behind a wedged one (the controller chain serializes the
        // ordering on its own).
        Task { await MaryRuntime.wakeStandby.noteAppReady() }
        // Revoked script consents are loud at launch, not discovered
        // mid-request. Detached: the scan loads the ability snapshot.
    }

    /// Seer/Totem come up after the engine so chat is usable even when the
    /// stack fails — every failure here mirrors a notice and continues in
    /// engine-only mode rather than blocking readiness.
    private func bootSeerStack() async {
        // The totem node UUID is the DB identity: adopt Totem's persisted id
        // (or mint one) on first boot, then pin it in config forever.
        var nodeID = config.state.totemNodeID
        if UUID(uuidString: nodeID) == nil {
            nodeID = TotemNodeIdentity.adoptOrMint(configured: "")
            config.center.update.send(ConfigService.Update.Meta(totemNodeID: nodeID))
        }
        MaryRuntime.applyCorpusIndexing(enabled: config.state.ambientCorpusIndexing)
        await MaryRuntime.applyServers(config: config.state, nodeID: nodeID)

        guard config.state.seerEnabled else {
            await MaryRuntime.connectSeerToBrain(chat: false, archiving: false)
            return
        }

        if config.state.autoStartServers {
            setReadiness("starting Seer and Totem…", ready: false)
            if let failure = await MaryRuntime.localStack.ensureRunning() {
                chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(
                    kind: .error("Local servers: \(failure) Chat continues without Seer.")))
            } else if config.state.totemGraphPolicyManaged {
                // Teach Totem's extractor Mary's ontology + co-mention
                // edges. Best-effort: a refusal never blocks boot.
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
            await MaryRuntime.connectSeerToBrain(chat: false, archiving: false)
            return
        }
        // ARCHIVING IS NOT THE BRAIN'S CHOICE. Sign-in succeeded, so Totem
        // takes deposits either way; only the chat lane answers to the Brain
        // card, so choosing "on device" keeps memory working.
        await MaryRuntime.connectSeerToBrain(
            chat: MaryRuntime.seerCarriesTurns(seerEnabled: true),
            archiving: true)
        // Transport rides the signed-in session, so it applies last.
        await MaryRuntime.applySeerTransport(config.state.seerTransport)
    }

    private func setReadiness(_ status: String?, ready: Bool) {
        chat.center.setReadiness.send(
            ChatService.SetReadiness.Meta(status: status, ready: ready)
        )
    }
}

// MARK: - Voice bar

/// THE BAR OWNS ITS OWN RELAY BOUNDARY, and that is the whole point of it
/// being a separate view. `voice.state.audioLevel` ticks ~60×/s while Mary
/// SPEAKS — the barge-in mic stays open and hears her own voice — and an
/// un-silenced `@Relay` republishes the entire view that declares it
/// (GraniteRelay.observe, throttled at 0.0167 s). Declared on
/// HomeSessionView, that re-evaluated ConversationPageView on every audio
/// frame, which tore down and restarted each brushstroke's fade-in: the
/// highlights flashing in and out. The relay lives here now, so the churn
/// stops at this bar and the page is re-rendered only by chat changes.
///
/// Reads and center sends still stay on the component that owns them — the
/// ownership moved WITH the bar rather than being split across the file.
private struct VoiceBar: View {
    @ObservedObject var streamVM: ConversationStreamViewModel

    @Relay var voice: VoiceService
    @Relay var chat: ChatService
    /// UN-SILENCED, unlike `HomeSessionView`'s. That one is silenced because
    /// republishing it re-renders `ConversationPageView` and costs the page
    /// its scroll position; this view hosts nothing of the sort and already
    /// re-renders at the audio meter's rate. Silencing it here would simply
    /// stop the ear glyph reacting to the setting.
    @Relay var config: ConfigService

    /// Generation ends before the char-by-char reveal does; the composer
    /// stays quiet until the page has settled.
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
                // Typed turns run outside Granite's streaming reducers
                // (snapshot-republish races); events funnel into the
                // single sync writer.
                Task {
                    await TextTurnRunner.shared.submit(text) { kind in
                        chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: kind))
                    }
                }
            }
        )
    }
}
