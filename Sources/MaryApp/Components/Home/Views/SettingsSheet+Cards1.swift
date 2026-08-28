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
                    // NARROWLY WHAT IS TRUE. A first draft of this line
                    // promised "nothing reaches the Seer server", which this
                    // switch does not deliver on its own: the voice backend
                    // defaults to Seer and archiving keeps depositing. A
                    // privacy sentence that is wrong about the two other
                    // settings on the same screen is worse than none.
                    Text("The turn is answered on this machine. Voice and memory keep their own settings — this one is the brain.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                case .hosted:
                    // THE SESSION, NOT AN ENVIRONMENT VARIABLE. This row used
                    // to demand a SEER_TOKEN in Mary's .env — a credential the
                    // app consumes NOWHERE. Every Seer request rides a Bearer
                    // token minted by SeerSession's account sign-in, which
                    // happens by itself at boot with the admin account; the
                    // only reader of SEER_TOKEN is the standalone voice probe,
                    // which has no session to mint from. So the old row sent
                    // people to edit a dotfile that would change nothing,
                    // while the actual requirement — being signed in — went
                    // unreported.
                    SeerSignInRow(
                        signedIn: seerSignedIn,
                        account: config.state.seerEmail,
                        whenSignedOut: "Not signed in — Mary signs in at boot; check the Servers panel.")
                    Text("Your words reach the cloud through the Seer server on this machine. Acting still runs on device.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
            }
        }
        .task { await refreshSeerSignIn() }
    }

    /// WHAT MARY REMEMBERS DOING.
    ///
    /// Recording is on by default, which is only defensible next to a switch
    /// that is easy to find and a delete that really deletes — see
    /// `BehavioralStore`. The size is shown because "delete my recordings"
    /// should be a decision rather than a leap.
    /// WHAT SHE LEARNS FROM YOUR WORK — the other half of memory, and a
    /// separate switch from the one below on purpose: recording what she DID
    /// and learning how you WRITE are different promises, and somebody may
    /// want one without the other.
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
