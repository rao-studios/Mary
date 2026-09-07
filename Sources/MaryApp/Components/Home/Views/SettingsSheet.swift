//
//  SettingsSheet.swift
//  Mary
//
//  WHAT: Tunables on MaryCards (voice, skill engine, VAD, projects).
//  OUT:  ConfigService.Update — runtime side effects apply immediately.
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryVoice
import Granite
import SwiftUI
import MaryRuntime

struct SettingsSheet: View {
    @Relay var config: ConfigService
    @Relay(.silence) var chat: ChatService
    @Environment(\.dismiss) private var dismiss

    @State var newProjectName: String = ""
    @State var newProjectPath: String = ""
    @State var permissions: [PermissionItem] = []
    @State var newPronunciationWord: String = ""
    @State var newPronunciationIPA: String = ""
    /// Seer signed-in. Nil until first read (no red flash on open).
    @State var seerSignedIn: Bool? = nil
    @State var codingDownloading = false
    @State var codingDownloadProgress: Double = 1
    @State var codingPrepared = false
    @State var codingStatus: String?
    /// What Seer reports for each backend. Empty until the first read.
    @State var providerStatuses: [SeerProviderStatus] = []
    @State var warmingLocal = false

    var voices: [String] {
        guard let dir = KokoroAssets.modelsDirectory() else { return ["af_heart"] }
        let found = KokoroEngine.availableVoices(in: dir)
        return found.isEmpty ? ["af_heart"] : found
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header

                permissionsCard

                skillsCard

                codingAgentCard

                voiceCard

                listeningCard

                projectsCard

                nativePluginsCard

                pronunciationsCard

                conversationCard

                corpusCard
            }
            .padding(.layer5)
        }
        .marySheet(ideal: CGSize(width: 480, height: 560))
        .background(Color.maryBG)
        .preferredColorScheme(.light)
        .onAppear {
            refreshPermissionStatus()
            Task { await refreshCodingAgentStatus() }
        }
        // Recompute on app activation — grant in System Settings, then cmd-tab back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
    }

    var header: some View {
        HStack {
            MaryMark(size: 18)
            Text("Settings")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.mary)
        }
    }

    func vadSlider(
        _ label: String, value: Binding<Double>,
        range: ClosedRange<Double>, format: String
    ) -> some View {
        HStack(spacing: .layer3) {
            Text(label)
                .font(.marySans(11))
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.maryMono(10))
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Bindings

    /// Corpus indexing, live and persisted. Off stops the next poll, not the next launch.
    var corpusIndexingBinding: Binding<Bool> {
        Binding(
            get: { config.state.ambientCorpusIndexing },
            set: { enabled in
                config.center.update.send(
                    ConfigService.Update.Meta(ambientCorpusIndexing: enabled))
                MaryRuntime.applyCorpusIndexing(enabled: enabled)
            }
        )
    }

    /// The sign-in state the status rows render — the SESSION's own answer,
    /// not an environment variable's.
    func refreshSeerSignIn() async {
        seerSignedIn = await MaryRuntime.seerSession.isAuthenticated
    }

    /// Hosted character (`seerVoice`), not the on-device Kokoro slot. Applied immediately.
    var voiceCharacterBinding: Binding<String> {
        Binding(
            get: { config.state.seerVoice },
            set: { id in
                config.center.update.send(ConfigService.Update.Meta(seerVoice: id))
                let backend = config.state.ttsBackend
                Task {
                    if let notice = await MaryRuntime.applyTTSBackend(
                        backend, hostedVoice: id) {
                        chat.center.mirrorVoice.send(
                            ChatService.MirrorVoice.Meta(kind: .error(notice)))
                    }
                }
            }
        )
    }

    var engineBinding: Binding<LLMEngineChoice> {
        Binding(
            get: { config.state.llmEngine },
            set: { choice in
                config.center.update.send(ConfigService.Update.Meta(llmEngine: choice))
                chat.center.setReadiness.send(
                    ChatService.SetReadiness.Meta(status: "switching engine…", ready: false)
                )
                // THE SERVER SIDE IS READ NOW, the choice is passed as chosen:
                // the config update above has not landed yet, so reading
                // `llmEngine` back inside the task would apply the OLD value.
                let seerEnabled = config.state.seerEnabled
                let skillEngine = config.state.skillEngine
                Task {
                    let error = await MaryRuntime.applyEngine(
                        choice,
                        skillEngine: skillEngine,
                        seerEnabled: seerEnabled,
                        progress: { status in
                            chat.center.setReadiness.send(
                                ChatService.SetReadiness.Meta(status: status, ready: false))
                        })
                    chat.center.setReadiness.send(
                        ChatService.SetReadiness.Meta(status: error, ready: error == nil)
                    )
                }
            }
        )
    }

    var skillEngineBinding: Binding<LLMEngineChoice> {
        Binding(
            get: { config.state.skillEngine },
            set: { choice in
                config.center.update.send(ConfigService.Update.Meta(skillEngine: choice))
                chat.center.setReadiness.send(
                    ChatService.SetReadiness.Meta(status: "switching skill engine…", ready: false)
                )
                let seerEnabled = config.state.seerEnabled
                let spoken = config.state.llmEngine
                Task {
                    let error = await MaryRuntime.applyEngine(
                        spoken,
                        skillEngine: choice,
                        seerEnabled: seerEnabled,
                        progress: { status in
                            chat.center.setReadiness.send(
                                ChatService.SetReadiness.Meta(status: status, ready: false))
                        })
                    chat.center.setReadiness.send(
                        ChatService.SetReadiness.Meta(status: error, ready: error == nil)
                    )
                }
            }
        )
    }

    var codingAgentEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.state.codingAgentEnabled },
            set: { enabled in
                config.center.update.send(
                    ConfigService.Update.Meta(codingAgentEnabled: enabled))
                let engine = config.state.codingEngine
                let seerEnabled = config.state.seerEnabled
                Task {
                    if enabled, engine.isOnDevice { codingDownloading = true }
                    let error = await MaryRuntime.applyCodingAgent(
                        enabled: enabled,
                        engine: engine,
                        seerEnabled: seerEnabled)
                    codingDownloading = false
                    codingStatus = error
                    codingPrepared = error == nil && enabled
                    if enabled, error != nil {
                        config.center.update.send(
                            ConfigService.Update.Meta(codingAgentEnabled: false))
                    }
                }
            }
        )
    }

    var codingEngineBinding: Binding<LLMEngineChoice> {
        Binding(
            get: { config.state.codingEngine },
            set: { choice in
                config.center.update.send(ConfigService.Update.Meta(codingEngine: choice))
                guard config.state.codingAgentEnabled else { return }
                let seerEnabled = config.state.seerEnabled
                Task {
                    if choice.isOnDevice { codingDownloading = true }
                    let error = await MaryRuntime.applyCodingAgent(
                        enabled: true,
                        engine: choice,
                        seerEnabled: seerEnabled)
                    codingDownloading = false
                    codingStatus = error
                    codingPrepared = error == nil
                    if error != nil {
                        config.center.update.send(
                            ConfigService.Update.Meta(codingAgentEnabled: false))
                    }
                }
            }
        )
    }

    func refreshCodingAgentStatus() async {
        codingPrepared = await CodingAgentSessions.shared.isPrepared()
        codingDownloadProgress = await CodingAgentSessions.shared.downloadProgress()
    }

    /// What Seer says about each backend, for the on-device status rows.
    func refreshProviderStatuses() async {
        providerStatuses = await MaryRuntime.providerStatuses()
    }

    /// The row for one backend, or nil while Seer has not answered yet.
    func providerStatus(_ choice: LLMEngineChoice) -> SeerProviderStatus? {
        providerStatuses.first { $0.choice == choice }
    }

    func warmOnDeviceModel() {
        warmingLocal = true
        Task {
            let error = await MaryRuntime.warmLocalProvider { status in
                chat.center.setReadiness.send(
                    ChatService.SetReadiness.Meta(status: status, ready: false))
            }
            warmingLocal = false
            chat.center.setReadiness.send(
                ChatService.SetReadiness.Meta(status: error, ready: error == nil))
            await refreshProviderStatuses()
        }
    }

    var historyLimitBinding: Binding<Int> {
        Binding(
            get: { config.state.historyMessageLimit },
            set: { limit in
                config.center.update.send(ConfigService.Update.Meta(historyMessageLimit: limit))
                Task { await MaryRuntime.brain.setHistoryLimit(limit) }
                // ONE number, BOTH stores. The brain's window and the page's
                // were separate for long enough that the caption below was
                // describing only half of what it claimed.
                chat.center.setHistoryLimit.send(
                    ChatService.SetHistoryLimit.Meta(limit: limit))
            }
        )
    }

    /// Apply now, not next turn/launch; same promise as applyAmbientCodeIndexing.

    /// Applies immediately, the ambient-voice rule: switching standby off
    /// must release the microphone this instant, not next launch.
    var wakeWordBinding: Binding<Bool> {
        Binding(
            get: { config.state.wakeWordEnabled },
            set: { enabled in
                config.center.update.send(
                    ConfigService.Update.Meta(wakeWordEnabled: enabled))
                MaryRuntime.applyWakeWord(enabled)
            }
        )
    }





    var seerTransportBinding: Binding<SeerTransportChoice> {
        Binding(
            get: { config.state.seerTransport },
            set: { choice in
                config.center.update.send(ConfigService.Update.Meta(seerTransport: choice))
                Task { await MaryRuntime.applySeerTransport(choice) }
            }
        )
    }

    var ttsBackendBinding: Binding<TTSBackend> {
        Binding(
            get: { config.state.ttsBackend },
            set: { backend in
                config.center.update.send(ConfigService.Update.Meta(ttsBackend: backend))
                Task {
                    if let notice = await MaryRuntime.applyTTSBackend(
                        backend, hostedVoice: config.state.seerVoice) {
                        chat.center.mirrorVoice.send(
                            ChatService.MirrorVoice.Meta(kind: .error(notice)))
                    }
                }
            }
        )
    }

    var voiceBinding: Binding<String> {
        Binding(
            get: { config.state.voice },
            set: { voice in
                config.center.update.send(ConfigService.Update.Meta(voice: voice))
                Task { _ = await MaryRuntime.bootKokoro(voice: voice) }
            }
        )
    }

    var styleBinding: Binding<SpeechStyleSelection> {
        Binding(
            get: { config.state.speechStyle },
            set: { style in
                config.center.update.send(ConfigService.Update.Meta(speechStyle: style))
                MaryRuntime.styleSelection = style
                Task { await MaryRuntime.speaker.setStyle(style.style) }
            }
        )
    }

    var sttBinding: Binding<STTBackend> {
        Binding(
            get: { config.state.sttBackend },
            set: { config.center.update.send(ConfigService.Update.Meta(sttBackend: $0)) }
        )
    }

    func updateVAD(_ mutate: (inout VADConfig) -> Void) {
        var vad = config.state.vad
        mutate(&vad)
        config.center.update.send(ConfigService.Update.Meta(vad: vad))
    }

    func saveProjects(_ projects: [ProjectRef]) {
        config.center.update.send(ConfigService.Update.Meta(projects: projects))
        let byName = Dictionary(projects.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a })
        Task {
            await MaryRuntime.installBrainConfiguration(projects: byName)
        }
    }

    func dotColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .maryGreen
        case .denied: return .maryError
        case .notDetermined: return Color.maryInk.opacity(0.25)
        case .unknown: return .maryGold
        }
    }

    func refreshPermissionStatus() {
        let accessibilityWasGranted = permissions.first {
            $0.kind == .accessibility
        }?.status == .granted
        let refreshed = PermissionsCenter.currentStatus()
        permissions = refreshed
        let accessibilityIsGranted = refreshed.first {
            $0.kind == .accessibility
        }?.status == .granted
        guard accessibilityWasGranted != accessibilityIsGranted else { return }
        // Dynamic readiness is frozen with the Ability snapshot. Returning
        // from macOS Settings refreshes that snapshot after a grant or a
        // revocation; no Native Plugin toggle or Mary restart is required.
        Task.detached(priority: .utility) {
            _ = AbilityLibrary.shared.reload()
        }
    }

    /// Compiled-provider off-list (deviations), never an enabled roster.
    func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !config.state.disabledPlugins.contains(id) },
            set: { isOn in
                var disabled = Set(config.state.disabledPlugins)
                if isOn { disabled.remove(id) } else { disabled.insert(id) }
                config.center.update.send(ConfigService.Update.Meta(
                    disabledPlugins: Array(disabled).sorted()))
                let projects = config.state.projectsByName
                Task { await MaryRuntime.installBrainConfiguration(projects: projects) }
            }
        )
    }


    func savePronunciations(_ pronunciations: [PronunciationRef]) {
        config.center.update.send(ConfigService.Update.Meta(customPronunciations: pronunciations))
        let byWord = Dictionary(
            pronunciations.filter { !$0.word.isEmpty && !$0.ipa.isEmpty }
                .map { ($0.word, $0.ipa) },
            uniquingKeysWith: { a, _ in a })
        Task {
            await MaryRuntime.applyPronunciations(byWord)
        }
    }
}
