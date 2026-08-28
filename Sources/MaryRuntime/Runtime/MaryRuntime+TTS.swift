//
//  MaryRuntime+TTS.swift
//  Mary
//
//  Moved verbatim from MaryRuntime.swift (phase 3): the TTS backend
//  boot/apply spine (bootKokoro, reapplyTTSBackend, applyTTSBackend and the
//  `activeTTSBackend` / `lastRequestedTTS` state they maintain), the
//  voice-notice channel (`onVoiceDegrade`, the once-per-episode Seer degrade
//  note, the revoked-script-consent notice), and the coding follow-up
//  bridge — the other boot-time bridge, started by installBrainConfiguration.
//
//  No behavior change and no promotions: every writer and reader of the
//  private state here moved together, so `private` still means private.
//

import MaryBrain
import MaryAdapters
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {

    /// What the speaker is actually synthesizing with right now — differs
    /// from config when the Mistral key is missing and Kokoro covers.
    nonisolated(unsafe) package private(set) static var activeTTSBackend: TTSBackend = .kokoro

    /// The on-device voice every fallback lands on when the requested name is
    /// not one the bundle carries.
    package static let defaultKokoroVoice = "af_heart"

    /// The Kokoro voice actually LOADED — which differs from the requested
    /// name when config named one the bundle has no embedding for. The app
    /// heals its own config from this, so the picker and the speaker cannot
    /// drift apart in silence.
    nonisolated(unsafe) package private(set) static var activeKokoroVoice: String?

    /// The bundled voice to actually load for `requested`: the request when it
    /// names a real on-device voice, `af_heart` otherwise, and failing that
    /// whatever the bundle does carry. Nil only when `voices/` is empty.
    ///
    /// THE SECOND LINE OF DEFENCE behind the config split. A hosted character
    /// slug (`fr_marie`) is a SERVER voice — Seer synthesizes it and no style
    /// embedding for it ships on device — so handed to the on-device engine it
    /// names a file that was never meant to exist. Config no longer stores one
    /// in the on-device slot; this makes sure that if one ever arrives again,
    /// by any route, the voice still comes up.
    package static func onDeviceVoice(named requested: String, in modelsDir: URL) -> String? {
        let available = KokoroEngine.availableVoices(in: modelsDir)
        if available.contains(requested) { return requested }
        if available.contains(defaultKokoroVoice) { return defaultKokoroVoice }
        return available.first
    }

    /// One-time boot: load `.env`, bring Kokoro up from the bundled assets.
    /// Returns a user-facing error string on failure, nil on success.
    package static func bootKokoro(voice: String) async -> String? {
        DotEnv.loadMaryEnvironment()
        guard let modelsDir = KokoroAssets.modelsDirectory() else {
            return "Kokoro models missing — run `git lfs pull` and rebuild."
        }
        guard let resolved = onDeviceVoice(named: voice, in: modelsDir) else {
            return "Kokoro voices missing — run `git lfs pull` and rebuild."
        }
        if resolved != voice {
            print("[voice] '\(voice)' is not an on-device voice — Kokoro speaks with '\(resolved)'.")
        }
        do {
            if await !kokoro.isLoaded {
                try await kokoro.loadModels(from: modelsDir)
            }
            try await kokoro.loadVoice(
                named: resolved, in: modelsDir.appendingPathComponent("voices"))
            activeKokoroVoice = resolved
            return nil
        } catch {
            return "Kokoro failed to load: \(error.localizedDescription)"
        }
    }

    /// The last CONFIGURED request, remembered so a later sign-in can replay
    /// it without the caller having to reach back into config.
    nonisolated(unsafe) private static var lastRequestedTTS: (backend: TTSBackend, voice: String)?

    /// Replay the last configured backend — called after a successful Seer
    /// sign-in so a session that booted unauthenticated recovers without the
    /// user touching the Speech picker.
    package static func reapplyTTSBackend() async -> String? {
        guard let lastRequestedTTS else { return nil }
        return await applyTTSBackend(
            lastRequestedTTS.backend, hostedVoice: lastRequestedTTS.voice)
    }

    /// Point the shared speaker at the configured TTS backend. Kokoro stays
    /// booted regardless — it is the instant-switch target and the fallback.
    /// Returns a user-facing notice when silently falling back, nil otherwise.
    package static func applyTTSBackend(_ backend: TTSBackend, hostedVoice: String) async -> String? {
        lastRequestedTTS = (backend, hostedVoice)
        switch backend {
        case .kokoro:
            await speaker.setSynthesizer(kokoro, policy: .onDevice)
            activeTTSBackend = .kokoro
            return nil
        case .seer:
            // SEER MEANS SEER — the user's decision, verbatim. The engine is
            // installed UNCONDITIONALLY: auth is a per-synthesis fact
            // (`tokenProvider` → `SeerSession.validToken`, which refreshes
            // and re-signs-in), never an apply-time pin. The old apply-time
            // guard parked the whole session on Kokoro when Seer happened to
            // be down at boot, and nothing ever re-applied — settings said
            // Seer, audio was Kokoro, forever.
            await seerTTS.setCharacter(.named(hostedVoice))
            // Per-chunk degradation: a dead Seer (its /v1/speak fatalErrors
            // when MISTRAL_API_KEY vanishes) hands each chunk to Kokoro —
            // after the engine's own re-auth-and-retry, and it says so.
            await seerTTS.setFallback(kokoro)
            await seerTTS.setOnDegrade { reason in
                Task { await noteSeerVoiceDegraded(reason) }
            }
            // A 401 despite locally-valid bookkeeping means the SERVER
            // rejected the token (restart, new signing key, revoked session)
            // — force a genuine refresh so the retry carries a new one.
            await seerTTS.setOnReauth {
                _ = await seerSession.refreshAfter401()
            }
            // Recovery re-arms the once-per-EPISODE notice: the second outage
            // must be as visible as the first.
            await seerTTS.setOnRecover {
                seerVoiceDegradeNoted.withLock { $0 = false }
            }
            // The realtime route renders server-side with its own voice id —
            // it follows the Character picker through here, narrowly, so a
            // voice change no longer waits for the next boot.
            await seerRealtime.setVoiceID("\(hostedVoice)_neutral")
            // Cloud chunks may grow after the first: fewer seams on long
            // passages, one prosody arc per batch.
            await speaker.setSynthesizer(seerTTS, policy: .cloud)
            activeTTSBackend = .seer
            if await !seerSession.isAuthenticated {
                return "Seer voice will connect once you're signed in — until then each line covers with the on-device voice."
            }
            return nil
        }
    }

    /// ONE NOTE PER EPISODE for per-chunk Seer voice degradation — enough to
    /// know it happened without narrating every network hiccup. The engine's
    /// `onRecover` re-arms it on the first successful Seer chunk after a
    /// degrade, so a later outage is as visible as the first. The app layer
    /// wires `onVoiceDegrade` to its notice channel (the chat mirror);
    /// headless tools leave it nil and the note goes to the log.
    nonisolated(unsafe) package static var onVoiceDegrade: (@Sendable (String) -> Void)?
    private static let seerVoiceDegradeNoted = OSAllocatedUnfairLock(initialState: false)
    private static func noteSeerVoiceDegraded(_ reason: String) async {
        let firstOfEpisode = seerVoiceDegradeNoted.withLock { noted -> Bool in
            guard !noted else { return false }
            noted = true
            return true
        }
        guard firstOfEpisode else { return }
        let note = "Seer voice covered with the on-device voice for a moment: \(reason)"
        if let onVoiceDegrade {
            onVoiceDegrade(note)
        } else {
            print("[voice] \(note)")
        }
    }

    /// Install the plugins, prompt provider, and subshell registry — called
    /// at boot and whenever the configured projects change. The prompt
    /// provider runs every turn, keeping the injected date and time fresh.
    /// Bridge coding-agent session completions to the brain's proactive voice,
    /// speaking ONLY on failure (a successful background edit lands silently —
    /// it just appears in Xcode). EVERY terminal snapshot lands in the Ability
    /// execution log regardless — the delegate ack binding logged the spawn; this row is
    /// the edit's real result. Started once for the process; the delegate
    /// recipe spawns on `CodingAgentManager.shared`, the same instance observed
    /// here.
    nonisolated(unsafe) private static var codingFollowUpBridgeStarted = false
}
