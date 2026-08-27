//
//  SettingsSheet+Cards1.swift
//

import MaryAmbient
import MaryBrain
import MaryAdapters
import MaryVoice
import Granite
import SwiftUI
import MaryRuntime

extension SettingsSheet {

    /// WHERE THE WORDS GO — on device, or through the local Seer server.
    ///
    /// The engine picker used to carry a per-vendor branch each, with an
    /// API-key status dot and a model-id field apiece. `LLMEngineChoice` says
    /// WHERE rather than WHO now, so this is two cases and the difference
    /// between them is the only one a person is actually choosing.
    var brainCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Brain")
                Picker("Engine", selection: engineBinding) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                switch config.state.llmEngine {
                case .local:
                    TextField("MLX model id", text: localModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.maryMono(11))
                    Text("Any mlx-community id works; applied on the next engine switch or relaunch.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                case .hosted:
                    HStack(spacing: .layer2) {
                        StatusDot(color: SeerAuth.isConfigured ? .maryGreen : .maryError)
                        Text(SeerAuth.isConfigured
                             ? "SEER_TOKEN found"
                             : "SEER_TOKEN missing — add it to Mary's .env")
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                    }
                    Text("Your words reach the cloud through the Seer server on this machine. Acting still runs on device.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
            }
        }
    }

    /// WHAT MARY REMEMBERS DOING.
    ///
    /// Recording is on by default, which is only defensible next to a switch
    /// that is easy to find and a delete that really deletes — see
    /// `BehavioralStore`. The size is shown because "delete my recordings"
    /// should be a decision rather than a leap.
    var behaviorCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("What she remembers doing")
                Toggle("Record what I ask for and what she does",
                       isOn: behavioralRecordingBinding)
                Text("One file per day, on this Mac only, readable by you. It holds your words and the text she wrote — that is what makes it worth keeping, and why it never leaves the machine.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                HStack(spacing: .layer3) {
                    Text(behaviorSizeCaption)
                        .font(.maryMono(10))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                    Spacer()
                    Button("Delete all", role: .destructive) {
                        Task {
                            await MaryRuntime.behavioralStore.purge()
                            await refreshBehaviorSize()
                        }
                    }
                    .buttonStyle(.mary)
                }
            }
        }
        .task { await refreshBehaviorSize() }
    }

    var permissionsCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack {
                    SectionLabel("Permissions")
                    Spacer()
                    Button("Grant everything…") {
                        Task {
                            await PermissionsCenter.requestAllRequestable()
                            permissions = PermissionsCenter.currentStatus()
                        }
                    }
                    .buttonStyle(.mary)
                }
                Text("Each prompt appears at most once — macOS remembers every answer. Gray dots haven't been asked yet; the three at the bottom are flipped by hand in System Settings.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))

                ForEach(permissions) { item in
                    HStack(spacing: .layer3) {
                        StatusDot(color: dotColor(item.status))
                        Text(item.title)
                            .font(.marySans(12, weight: .medium))
                        Text(item.why)
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.5))
                        Spacer()
                        if item.status != .granted {
                            if item.isRequestable {
                                Button(item.status == .denied ? "Settings…" : "Grant") {
                                    if item.status == .denied {
                                        PermissionsCenter.openSettingsPane(item)
                                    } else {
                                        Task {
                                            _ = await PermissionsCenter.request(item.kind)
                                            permissions = PermissionsCenter.currentStatus()
                                        }
                                    }
                                }
                                .buttonStyle(.maryQuiet)
                            } else {
                                Button("Settings…") {
                                    Task {
                                        // Registers the attempt first so the
                                        // app appears in the pane's list.
                                        _ = await PermissionsCenter.request(item.kind)
                                        PermissionsCenter.openSettingsPane(item)
                                        permissions = PermissionsCenter.currentStatus()
                                    }
                                }
                                .buttonStyle(.maryQuiet)
                            }
                        }
                    }
                }
                Text("Speaker output needs no permission on macOS.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var voiceCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Voice")
                Picker("Chat transport", selection: seerTransportBinding) {
                    ForEach(SeerTransportChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text(config.state.seerTransport == .realtime
                     ? "Realtime streams Seer's own voice over one socket — speech starts in about a second while retrieval catches up. Falls back to Classic if the route can't connect."
                     : "Classic streams text and synthesizes speech with the backend below.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.7))

                Picker("Speech", selection: ttsBackendBinding) {
                    ForEach(TTSBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                // The settings-vs-speaker divergence, finally visible:
                // the radio reads config, the audio follows the
                // runtime, and the two used to disagree in silence.
                if MaryRuntime.activeTTSBackend != config.state.ttsBackend {
                    HStack(spacing: .layer2) {
                        StatusDot(color: .maryError)
                        Text("Speaking with \(MaryRuntime.activeTTSBackend.displayName) right now — the selected voice isn't active.")
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                    }
                }

                if config.state.ttsBackend == .seer {
                    Picker("Character", selection: voiceCharacterBinding) {
                        ForEach(VoiceCharacter.all) { character in
                            Text(character.displayName).tag(character.id)
                        }
                    }
                    HStack(spacing: .layer2) {
                        StatusDot(color: SeerAuth.isConfigured ? .maryGreen : .maryError)
                        Text(SeerAuth.isConfigured
                             ? "SEER_TOKEN found"
                             : "SEER_TOKEN missing — Kokoro speaks until it's added")
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                    }
                    Text("Speaks through the local Seer server; Kokoro covers any chunk Seer can't. Needs the Seer sign-in from the Servers panel.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                    Text("Emotion is chosen per sentence, on-device.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                } else {
                    Picker("Voice", selection: voiceBinding) {
                        ForEach(voices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Style", selection: styleBinding) {
                        ForEach(SpeechStyleSelection.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
