//
//  SettingsSheet+Cards2.swift
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryVoice
import Granite
import SwiftUI
import MaryRuntime

extension SettingsSheet {

    var listeningCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Listening")
                Picker("Transcriber", selection: sttBinding) {
                    ForEach(STTBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Both transcribe on this Mac; nothing you say leaves it.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                if config.state.sttBackend == .analyzer {
                    speechModelRow
                }
                Toggle("Wake word — \u{201C}Hey Mary\u{201D}", isOn: wakeWordBinding)
                Text("While sessions are off, a wake-only microphone listens for her name — the macOS mic indicator stays lit. Anything not addressed to her is discarded on-device, never stored. \u{201C}Stop listening\u{201D} ends a session by voice.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                vadSlider(
                    "Speech threshold",
                    value: Binding(
                        get: { Double(config.state.vad.speechStartRMS) },
                        set: { newValue in
                            updateVAD { vad in
                                vad.speechStartRMS = Float(newValue)
                                vad.speechContinueRMS = Float(newValue) * 0.53
                            }
                        }
                    ),
                    range: 0.005...0.06, format: "%.3f"
                )
                vadSlider(
                    "Silence to end (ms)",
                    value: Binding(
                        get: { Double(config.state.vad.hangoverMs) },
                        set: { newValue in
                            updateVAD { vad in vad.hangoverMs = Int(newValue) }
                        }
                    ),
                    range: 400...2000, format: "%.0f"
                )
                Text("Applied when the next listening session starts.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var speechModelRow: some View {
        VStack(alignment: .leading, spacing: .layer1) {
            HStack(spacing: .layer2) {
                Circle()
                    .fill(speechModelDotColor)
                    .frame(width: 6, height: 6)
                Text(speechModelStatusText)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                Spacer()
                if speechModelStatus == .notInstalled {
                    Button(speechModelDownloading ? "Downloading…" : "Download") {
                        downloadSpeechModel()
                    }
                    .buttonStyle(.maryQuiet)
                    .disabled(speechModelDownloading)
                }
            }
            if let speechModelError {
                Text(speechModelError)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryError)
            }
        }
    }

    var speechModelDotColor: Color {
        switch speechModelStatus {
        case .installed: return .maryGreen
        case .notInstalled, .downloading: return .maryGold
        case .unsupported: return .maryError
        case nil: return Color.maryInk.opacity(0.25)
        }
    }

    var speechModelStatusText: String {
        if speechModelDownloading { return "Downloading the on-device model\u{2026}" }
        switch speechModelStatus {
        case .installed: return "On-device model ready."
        case .notInstalled: return "On-device model not downloaded yet."
        case .downloading: return "Someone else is already downloading it."
        case .unsupported: return "Unsupported for \(Locale.current.identifier)."
        case nil: return "Checking the on-device model\u{2026}"
        }
    }

    var projectsCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Projects")
                Text("Voice commands can open these in VS Code — \"open \(config.state.projects.first?.name ?? "mary") and start the coding agent\".")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))

                ForEach(config.state.projects) { project in
                    HStack(spacing: .layer3) {
                        Text(project.name)
                            .font(.marySans(12, weight: .medium))
                        Text(project.path)
                            .font(.maryMono(10))
                            .foregroundStyle(Color.maryInk.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            saveProjects(config.state.projects.filter { $0.id != project.id })
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Color.maryError.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: .layer2) {
                    TextField("name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("path", text: $newProjectPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        if let url = FilePicker.pickFiles().first {
                            newProjectPath = url.path
                            if newProjectName.isEmpty {
                                newProjectName = url.lastPathComponent
                            }
                        }
                    }
                    .buttonStyle(.maryQuiet)
                    Button("Add") {
                        let name = newProjectName.trimmingCharacters(in: .whitespaces)
                        let path = newProjectPath.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !path.isEmpty else { return }
                        saveProjects(config.state.projects + [ProjectRef(name: name, path: path)])
                        newProjectName = ""
                        newProjectPath = ""
                    }
                    .buttonStyle(.mary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var nativePluginsCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Native Plugins")
                Text("Built into Mary, and generic every one — the typer types wherever a cursor is, the prose surface reads whatever declares one. The applications themselves arrive as Abilities and do not appear here.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                ForEach(MaryAdapterCatalog.adapters().map(\.name).sorted(), id: \.self) { id in
                    Toggle(id.replacingOccurrences(of: "_", with: " "), isOn: pluginBinding(id))
                        .font(.marySans(12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var pronunciationsCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Pronunciations")
                Text("Teach Mary words she says wrong — Kokoro IPA, e.g. Ritesh → \u{0279}\u{025b}t\u{02c8}\u{025b}\u{0283}. Her user's name is built in.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))

                ForEach(config.state.customPronunciations) { entry in
                    HStack(spacing: .layer3) {
                        Text(entry.word)
                            .font(.marySans(12, weight: .medium))
                        Text(entry.ipa)
                            .font(.maryMono(11))
                            .foregroundStyle(Color.maryInk.opacity(0.6))
                        Spacer()
                        Button {
                            savePronunciations(config.state.customPronunciations.filter { $0.id != entry.id })
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Color.maryError.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: .layer2) {
                    TextField("word", text: $newPronunciationWord)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("IPA", text: $newPronunciationIPA)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let word = newPronunciationWord.trimmingCharacters(in: .whitespaces)
                        let ipa = newPronunciationIPA.trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty, !ipa.isEmpty else { return }
                        savePronunciations(config.state.customPronunciations + [PronunciationRef(word: word, ipa: ipa)])
                        newPronunciationWord = ""
                        newPronunciationIPA = ""
                    }
                    .buttonStyle(.mary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var conversationCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack {
                    SectionLabel("Conversation")
                    Spacer()
                    Button("Forget everything") {
                        chat.center.reset.send()
                    }
                    .buttonStyle(.maryQuiet)
                }
                Stepper(
                    "Context window: \(config.state.historyMessageLimit) messages",
                    value: historyLimitBinding, in: 4...40, step: 2)
                Text("Mary keeps the last \(config.state.historyMessageLimit) spoken messages — on the page and in mind; older ones fall away so stale context can't linger.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
