//
//  MaryRuntime+TTS.swift
//  MaryRuntime
//
//  WHAT: TTS boot/apply spine, voice-notice channel, coding follow-up bridge.
//  IN:   Config Speech picker, Seer sign-in, installBrainConfiguration
//  OUT:  KokoroEngine / SeerTTS / KokoroStreamSpeaker / brain.emitCodingFollowUp
//  PIN:  Hosted character slugs never load as on-device voices. Seer installs
//        unconditionally; auth is per-synthesis.
//

import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {

    /// What the speaker is synthesizing with now. Differs from config when Kokoro covers.
    nonisolated(unsafe) package private(set) static var activeTTSBackend: TTSBackend = .kokoro

    /// On-device voice every fallback lands on when the request is not in the bundle.
    package static let defaultKokoroVoice = "af_heart"

    /// Kokoro voice actually loaded. App heals config from this so picker and speaker agree.
    nonisolated(unsafe) package private(set) static var activeKokoroVoice: String?

    /// Bundled voice for `requested`: request if present, else `af_heart`, else first.
    /// Hosted slugs (`fr_marie`) have no on-device embedding — never load them as files.
    package static func onDeviceVoice(named requested: String, in modelsDir: URL) -> String? {
        let available = KokoroEngine.availableVoices(in: modelsDir)
        if available.contains(requested) { return requested }
        if available.contains(defaultKokoroVoice) { return defaultKokoroVoice }
        return available.first
    }

    /// One-time boot: load `.env`, bring Kokoro up. User-facing error string or nil.
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

    /// Last configured request — replay after Seer sign-in without reaching into config.
    nonisolated(unsafe) private static var lastRequestedTTS: (backend: TTSBackend, voice: String)?

    /// Replay last configured backend after a successful Seer sign-in.
    package static func reapplyTTSBackend() async -> String? {
        guard let lastRequestedTTS else { return nil }
        return await applyTTSBackend(
            lastRequestedTTS.backend, hostedVoice: lastRequestedTTS.voice)
    }

    /// Point the shared speaker at the configured TTS backend. Kokoro stays booted.
    package static func applyTTSBackend(_ backend: TTSBackend, hostedVoice: String) async -> String? {
        lastRequestedTTS = (backend, hostedVoice)
        switch backend {
        case .kokoro:
            await speaker.setSynthesizer(kokoro, policy: .onDevice)
            activeTTSBackend = .kokoro
            return nil
        case .seer:
            // Auth is per-synthesis (`tokenProvider` → SeerSession.validToken), not apply-time.
            await seerTTS.setCharacter(.named(hostedVoice))
            // Dead Seer hands each chunk to Kokoro after re-auth-and-retry.
            await seerTTS.setFallback(kokoro)
            await seerTTS.setOnDegrade { reason in
                Task { await noteSeerVoiceDegraded(reason) }
            }
            // 401 despite local bookkeeping: server rejected the token — force refresh.
            await seerTTS.setOnReauth {
                _ = await seerSession.refreshAfter401()
            }
            // Recovery re-arms the once-per-episode notice.
            await seerTTS.setOnRecover {
                seerVoiceDegradeNoted.withLock { $0 = false }
            }
            // Realtime route follows the Character picker through here.
            await seerRealtime.setVoiceID("\(hostedVoice)_neutral")
            // Cloud chunks may grow after the first: fewer seams, one prosody arc.
            await speaker.setSynthesizer(seerTTS, policy: .cloud)
            activeTTSBackend = .seer
            if await !seerSession.isAuthenticated {
                return "Seer voice will connect once you're signed in — until then each line covers with the on-device voice."
            }
            return nil
        }
    }

    /// One note per episode for Seer voice degradation. onRecover re-arms.
    /// App wires onVoiceDegrade to the chat mirror; headless tools log.
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

    /// Coding-agent completions → proactive voice. Speak only on background failure.
    /// Awaited pair-program sessions return through the workflow — do not speak twice.
    nonisolated(unsafe) private static var codingFollowUpBridgeStarted = false
    static func startCodingFollowUpBridge() {
        guard !codingFollowUpBridgeStarted else { return }
        codingFollowUpBridgeStarted = true
        Task {
            await CodingAgentSessions.shared.onCompletion { completion in
                guard completion.delivery == .background, !completion.ok else { return }
                Task {
                    await brain.emitCodingFollowUp(failureReason: completion.summary)
                }
            }
        }
    }
}
