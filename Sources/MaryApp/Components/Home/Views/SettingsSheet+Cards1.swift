//
//  SettingsSheet+Cards1.swift
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryVoice
import Granite
import SwiftUI
import MaryRuntime

extension SettingsSheet {

    /// LANE B — where skill invocations are synthesized. Spoken replies are
    /// Voice (Lane A); tools still run on this Mac either way.
    var skillsCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Skills (Lane B)")
                Picker("Skill engine", selection: skillEngineBinding) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                switch config.state.skillEngine {
                case .local:
                    TextField("MLX model id", text: localModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.maryMono(11))
                    Text("Skill invocations are decided on this machine (on-device MLX). The skills themselves still run here. Spoken replies are Voice (Lane A).")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                case .hosted:
                    SeerSignInRow(
                        signedIn: seerSignedIn,
                        account: config.state.seerEmail,
                        whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                    Text("Skill invocations are synthesized through the Seer server on this machine (not the spoken chat lane, not corpus annotation). The skills still run on this Mac. Needs Chat through Seer in the Servers panel.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                    if config.state.llmEngine == .local {
                        Text("Voice is on-device, so this loop also supplies any spoken wrap-up — Seer persona and retrieval stay off.")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                }
            }
        }
        .task { await refreshSeerSignIn() }
    }

    /// Pair-coding faculty. On/off is separate from WHERE synthesis runs —
    /// on-device MLX or Seer's `/v1/code/complete`. Edits stay on this Mac.
    var codingAgentCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Coding Agent")
                Toggle("Use the coding agent", isOn: codingAgentEnabledBinding)
                    .disabled(codingDownloading)
                Text("Pair-coding edits files in the focused project. Switch the faculty on, then choose where invocations are synthesized.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))

                Picker("Coding engine", selection: codingEngineBinding) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(codingDownloading)

                switch config.state.codingEngine {
                case .local:
                    Text("Invocations are decided on this Mac. Download a model, then switch the faculty on — selecting a downloaded snapshot is what turns local coding on.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                    TextField("MLX Hub id", text: codingAgentModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.maryMono(11))
                        .disabled(codingDownloading)
                    HStack(spacing: .layer3) {
                        Button("Download") { downloadCodingModel() }
                            .buttonStyle(.mary)
                            .disabled(codingDownloading)
                        Button("Default model") { restoreDefaultCodingModel() }
                            .buttonStyle(.maryQuiet)
                            .disabled(codingDownloading)
                        Spacer()
                    }
                    if codingDownloading {
                        ProgressView(value: codingDownloadProgress, total: 1)
                        Text("Downloading \(Int(codingDownloadProgress * 100))% — about 6.7 GB the first time.")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                case .hosted:
                    SeerSignInRow(
                        signedIn: seerSignedIn,
                        account: config.state.seerEmail,
                        whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                    Text("Invocations are synthesized through Seer (model chosen on the server, not here). File tools still run on this Mac, jailed to the project. Needs Chat through Seer in the Servers panel.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }

                if codingPrepared || config.state.codingAgentEnabled {
                    Text("Ready. The coding agent will edit the focused project on disk.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                if let codingStatus {
                    Text(codingStatus)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryError)
                }
            }
        }
        .task(id: codingDownloading) {
            guard codingDownloading else { return }
            while !Task.isCancelled, codingDownloading {
                codingDownloadProgress = await CodingAgentSessions.shared.downloadProgress()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await refreshCodingAgentStatus()
        }
        .task { await refreshCodingAgentStatus() }
    }

    /// WHAT SHE LEARNS FROM YOUR WORK — corpus indexing of project shape
    /// and writing style. Ability turns live in Totem, not here.
    var corpusCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("What she learns from your work")
                Toggle("Index the projects I work in", isOn: corpusIndexingBinding)
                Text("When you settle on a file, Mary reads its neighbourhood and remembers the shape — and notices how you tend to write. Only declaration headers and short generated summaries are kept; never the body of your work.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                Text("Open the Corpus pane to see every unit, pin a label, or forget one.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
        }
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

                // WHOSE GRANT IS THIS, ANYWAY. A development build launched
                // from a terminal is that terminal's responsibility as far as
                // TCC is concerned, so Accessibility reads granted, "Grant
                // everything" skips it as already done, and Mary never
                // appears in the Accessibility list. Every part of that is
                // correct and the screen still looked broken, because it
                // reported the permission without reporting who holds it.
                if let holder = PermissionsCenter.accessibilityGrantHolder {
                    HStack(alignment: .top, spacing: .layer2) {
                        StatusDot(color: .maryGold)
                        Text("Accessibility here is inherited from \(holder), not Mary's own — which is why she isn't in the Accessibility list and why granting again changes nothing. Run build/Mary.app (./scripts/make-app.sh) for Mary to hold it herself.")
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                    }
                }

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
                SectionLabel("Voice (Lane A)")
                Picker("Spoken replies", selection: engineBinding) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                switch config.state.llmEngine {
                case .local:
                    Text("Spoken replies are produced on this machine. Skill invocations have their own control under Skills (Lane B).")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                case .hosted:
                    SeerSignInRow(
                        signedIn: seerSignedIn,
                        account: config.state.seerEmail,
                        whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                    Text("Spoken replies stream from Seer (SSE or realtime below). Skills are separate — Lane B.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }

                Picker("Chat transport", selection: seerTransportBinding) {
                    ForEach(SeerTransportChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text(config.state.llmEngine == .local
                     ? "Transport applies when spoken replies are hosted. On-device Voice does not use this socket."
                     : (config.state.seerTransport == .realtime
                        ? "Realtime streams Seer's own voice over one socket — speech starts in about a second while retrieval catches up. Falls back to Classic if the route can't connect."
                        : "Classic streams text and synthesizes speech with the backend below."))
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
                    // Same correction as the Brain card's row: the cloud
                    // voice needs the SIGN-IN, not a token in a dotfile.
                    SeerSignInRow(
                        signedIn: seerSignedIn,
                        account: config.state.seerEmail,
                        whenSignedOut: "Not signed in — Kokoro speaks until the Seer sign-in completes.")
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
        .task { await refreshSeerSignIn() }
    }

}

/// The Seer sign-in as a status row: the session's answer, three states.
///
/// NIL IS A REAL STATE. The read is an actor hop that lands a frame after the
/// sheet opens; until it does, the row says it is checking rather than
/// guessing. A dot that guessed red would tell a signed-in user to go fix
/// something for the length of a frame — and screenshots freeze frames.
private struct SeerSignInRow: View {
    let signedIn: Bool?
    let account: String
    let whenSignedOut: String

    var body: some View {
        HStack(spacing: .layer2) {
            StatusDot(color: signedIn == nil
                ? Color.maryInk.opacity(0.35)
                : signedIn == true ? .maryGreen : .maryError)
            Text(signedIn == nil
                ? "Checking the Seer sign-in…"
                : signedIn == true ? "Signed in to Seer as \(account)" : whenSignedOut)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.7))
        }
    }
}
