//
//  SettingsSheet.swift
//  Mary
//
//  Everything tunable, on MaryCards: which brain answers, which voice
//  speaks, how listening endpoints, and which projects voice commands can
//  open. Every control writes through ConfigService.Update; runtime side
//  effects (engine swap, voice reload, prompt/dispatcher rebuild) apply
//  immediately.
//

import MaryAmbient
import MaryBrain
import MaryAdapters
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
    /// Bytes the behavioral record occupies, refreshed when its card appears.
    @State var behaviorSizeOnDisk: Int = 0
    /// Whether the Seer session is signed in. Nil until the first read
    /// answers — a dot that defaulted to red would flash "not signed in" at
    /// every open of the sheet, on a machine where boot signed in seconds ago.
    @State var seerSignedIn: Bool? = nil

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

                brainCard

                voiceCard

                listeningCard

                projectsCard

                nativePluginsCard

                pronunciationsCard

                conversationCard

                // WHAT MARY REMEMBERS DOING — the one card for the behavioral
                // record. It is here rather than buried in a debug pane
                // because the data is the user's words and Mary's edits in
                // plaintext, and a recording somebody has to go looking for
                // the switch to is a recording they did not really consent to.
                behaviorCard
            }
            .padding(.layer5)
        }
        .frame(width: 480, height: 560)
        .background(Color.maryBG)
        .preferredColorScheme(.light)
        .onAppear {
            refreshPermissionStatus()
        }
        // The user grants in System Settings, then cmd-tabs back — recompute
        // on every app activation so the card reflects the grant instantly
        // instead of waiting for the sheet to be closed and reopened. The
        // status calls are live (AXIsProcessTrusted etc.); only this trigger
        // was missing.
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

    var behavioralRecordingBinding: Binding<Bool> {
        Binding(
            get: { config.state.behavioralRecording },
            set: { enabled in
                config.center.update.send(
                    ConfigService.Update.Meta(behavioralRecording: enabled))
                // THE LIVE FLAG TOO, not only the persisted one. The store
                // reads it per append, so a switch flipped mid-session takes
                // effect on the next turn — which is what a person expects of
                // a switch, and the only version of "off" worth having.
                MaryRuntime.behavioralRecordingEnabledBox.withLock { $0 = enabled }
            }
        )
    }

    var behaviorSizeCaption: String {
        guard behaviorSizeOnDisk > 0 else { return "Nothing recorded yet" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(behaviorSizeOnDisk), countStyle: .file) + " on disk"
    }

    func refreshBehaviorSize() async {
        behaviorSizeOnDisk = await MaryRuntime.behavioralStore.sizeOnDisk()
    }

    /// The sign-in state the status rows render — the SESSION's own answer,
    /// not an environment variable's.
    func refreshSeerSignIn() async {
        seerSignedIn = await MaryRuntime.seerSession.isAuthenticated
    }

    /// Which of the cloud voice's characters speaks.
    /// THE HOSTED CHARACTER, written to its own field. This picker used to
    /// write the on-device slot — the one boot hands to Kokoro — so choosing
    /// Marie armed the next launch to die on `'fr_marie.json' not found`. It
    /// also only wrote config: the character reached the speaker at the next
    /// boot and not before, so the picker and the voice disagreed until then.
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
                let modelID = config.state.localModelID
                // THE SERVER SIDE IS READ NOW, the choice is passed as chosen:
                // the config update above has not landed yet, so reading
                // `llmEngine` back inside the task would apply the OLD value.
                let seerEnabled = config.state.seerEnabled
                Task {
                    let error = await MaryRuntime.applyEngine(
                        choice, localModelID: modelID, seerEnabled: seerEnabled)
                    chat.center.setReadiness.send(
                        ChatService.SetReadiness.Meta(status: error, ready: error == nil)
                    )
                }
            }
        )
    }

    var localModelBinding: Binding<String> {
        Binding(
            get: { config.state.localModelID },
            set: { config.center.update.send(ConfigService.Update.Meta(localModelID: $0)) }
        )
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

    /// Applies immediately rather than next turn: turning indexing off should
    /// stop the crawl now, not after the next thing the user says.
    /// Applies IMMEDIATELY rather than next launch — `applyAmbientCodeIndexing`
    /// below makes the same promise for the same reason: a capability the user
    /// just switched off must stop being a capability, not stop next time.

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

    /// Turning one COMPILED provider off.
    ///
    /// THE DEVIATION LIST IS WHAT IS STORED — what is turned OFF, never what
    /// is on. Storing the enabled roster froze today's list at the first
    /// toggle, and everything shipped afterwards was absent from it and
    /// silently never installed for anyone who had ever opened Settings.
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
