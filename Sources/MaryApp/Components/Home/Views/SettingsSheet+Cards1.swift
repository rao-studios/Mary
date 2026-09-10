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

                SewnSignInRow(
                    signedIn: sewnSignedIn,
                    account: config.state.sewnEmail,
                    whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                backendCaption(
                    config.state.skillEngine,
                    lane: "Skill invocations are synthesized")
                Text("The skills themselves always run on this Mac. Spoken replies are Voice (Lane A).")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))

                Divider().overlay(Color.maryBorder)

                HStack(spacing: .layer3) {
                    Text("Price per model call")
                        .font(.marySans(11))
                    Spacer()
                    TextField(
                        "0.00",
                        value: modelCallPriceBinding,
                        format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .font(.maryMono(11))
                        .frame(width: 90)
                }
                Text("Only used by Ability Studio's per-run estimate. Mary makes no claim about what a call costs — set what yours does.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
        }
        .task {
            await refreshSewnSignIn()
            await refreshProviderStatuses()
        }
    }

    var modelCallPriceBinding: Binding<Double> {
        Binding(
            get: { config.state.modelCallPriceUSD },
            set: { next in
                config.center.update.send(
                    ConfigService.Update.Meta(modelCallPriceUSD: max(0, next)))
            })
    }

    /// Pair-coding faculty. On/off is separate from WHICH BACKEND synthesizes
    /// the rounds; every one of them rides Sewn. Edits stay on this Mac.
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

                SewnSignInRow(
                    signedIn: sewnSignedIn,
                    account: config.state.sewnEmail,
                    whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                backendCaption(
                    config.state.codingEngine,
                    lane: "Coding rounds are synthesized")
                Text("File tools still run on this Mac, jailed to the project.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))

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
        .task {
            await refreshCodingAgentStatus()
            await refreshProviderStatuses()
        }
    }

    /// WHAT SHE LEARNS FROM YOUR WORK — corpus indexing of project shape
    /// and writing style. Ability turns live in Thread, not here.
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

                // Terminal-launched TCC: grant is the parent's, not Mary's.
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

                SewnSignInRow(
                    signedIn: sewnSignedIn,
                    account: config.state.sewnEmail,
                    whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                backendCaption(config.state.llmEngine, lane: "Spoken replies are produced")
                Text("Skill invocations are separate — Lane B.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))

                Picker("Chat transport", selection: sewnTransportBinding) {
                    ForEach(SewnTransportChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text(false
                     ? ""
                     : (config.state.sewnTransport == .realtime
                        ? "Realtime streams Sewn's own voice over one socket — speech starts in about a second while retrieval catches up. Falls back to Classic if the route can't connect."
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

                if config.state.ttsBackend == .sewn {
                    Picker("Character", selection: voiceCharacterBinding) {
                        ForEach(VoiceCharacter.all) { character in
                            Text(character.displayName).tag(character.id)
                        }
                    }
                    // Same correction as the Brain card's row: the cloud
                    // voice needs the SIGN-IN, not a token in a dotfile.
                    SewnSignInRow(
                        signedIn: sewnSignedIn,
                        account: config.state.sewnEmail,
                        whenSignedOut: "Not signed in — Kokoro speaks until the Sewn sign-in completes.")
                    Text("Speaks through the local Sewn server; Kokoro covers any chunk Sewn can't. Needs the Sewn sign-in from the Servers panel.")
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
        .task { await refreshSewnSignIn() }
    }

    /// One sentence naming which backend serves this lane, plus the honest
    /// on-device row: whether Sewn has the model, and what to do if not.
    @ViewBuilder
    func backendCaption(_ choice: LLMEngineChoice, lane: String) -> some View {
        switch choice {
        case .mistral:
            Text("\(lane) by Mistral's hosted API, reached by the Sewn server on this machine.")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        case .tinker:
            Text("\(lane) by Thinking Machines, reached by the Sewn server on this machine. Sewn needs TINKER_API_KEY in its .env.")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        case .local:
            Text("\(lane) on this machine, by Sewn's on-device model. Nothing leaves the Mac for this lane; speech, vision and embeddings are separate.")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
            onDeviceStatusRow
        }
    }

    /// What Sewn says about its on-device backend, and a way to load it now.
    @ViewBuilder
    var onDeviceStatusRow: some View {
        let status = providerStatus(.local)
        HStack(spacing: .layer2) {
            StatusDot(color: status == nil
                ? Color.maryInk.opacity(0.35)
                : status?.state == "ready" ? .maryGreen
                    : status?.available == true ? .maryGold : .maryError)
            Text(onDeviceStatusText(status))
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.7))
            Spacer()
            if status?.state != "ready" {
                Button("Warm now") { warmOnDeviceModel() }
                    .buttonStyle(.maryQuiet)
                    .disabled(warmingLocal || status?.available == false)
            }
        }
        if let reason = status?.reason {
            Text(reason)
                .font(.marySans(10))
                .foregroundStyle(Color.maryError)
        }
        Text("The model lives in Sewn, not in Mary — one copy serves every lane.")
            .font(.marySans(10))
            .foregroundStyle(Color.maryInk.opacity(0.45))
    }

    func onDeviceStatusText(_ status: SewnProviderStatus?) -> String {
        guard let status else { return "Checking Sewn's on-device backend…" }
        switch status.state {
        case "ready": return "Loaded and ready — \(status.model)"
        case "loading":
            let percent = status.progress.map { " (\(Int($0 * 100))%)" } ?? ""
            return "Sewn is loading the model\(percent)…"
        case "cold": return "Not loaded yet — the first turn will load it."
        default: return "Unavailable"
        }
    }
}

/// Sewn sign-in row; nil means still checking (actor hop).
private struct SewnSignInRow: View {
    let signedIn: Bool?
    let account: String
    let whenSignedOut: String

    var body: some View {
        HStack(spacing: .layer2) {
            StatusDot(color: signedIn == nil
                ? Color.maryInk.opacity(0.35)
                : signedIn == true ? .maryGreen : .maryError)
            Text(signedIn == nil
                ? "Checking the Sewn sign-in…"
                : signedIn == true ? "Signed in to Sewn as \(account)" : whenSignedOut)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.7))
        }
    }
}
