//
//  main.swift
//  mary-voice-probe
//
//  WHAT: Exercise each MaryVoice stage from the terminal.
//  OUT:  speak / mic-levels / vad / stt / loop
//

import MaryVoice
import Foundation

let usage = """
mary-voice-probe <command>

commands:
  speak <text> [--voice <name>] [--style <preset>] [--stream] [--trace]
        synthesize and play via Kokoro
        presets: neutral excited calm sad assertive whisper
        --stream feeds the text word-by-word through KokoroStreamSpeaker
        --trace prints the pronunciation table before playback
  sewn-speak <text> [--voice <name>] [--url <base>] [--stream]
        synthesize and play via Sewn, Mary's one cloud voice; emotion is
        classified on-device from the first chunk and PINNED for the reply.
        Needs a Sewn server (default http://127.0.0.1:8080) and, if it asks
        for one, a token in SEWN_TOKEN.
  pronounce <text>
        trace how every word resolves (no audio)
  g2p-validate [--sample N] [--seed S]
        score the neural G2P against ground-truth cache pairs;
  voices
        list bundled Kokoro voices
  mic-levels                      print live RMS levels from the mic
  vad                             print VAD speechStart/speechEnd events
  stt                             transcribe one utterance
  loop                            echo mode: repeat what you say (no LLM)
  wake                            standby wake-word listener: prints every
                                  WakeEvent ("Hey Mary[, request]") until
                                  Ctrl-C; non-wake speech is discarded
"""

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func flagValue(_ arguments: inout [String], _ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func boolFlag(_ arguments: inout [String], _ flag: String) -> Bool {
    guard let index = arguments.firstIndex(of: flag) else { return false }
    arguments.remove(at: index)
    return true
}

func resolveModelsDir() -> URL {
    guard let dir = KokoroAssets.modelsDirectory() else {
        fail("Kokoro models not found in the MaryVoice bundle. Run `git lfs pull`?")
    }
    return dir
}

func loadedEngine(voice: String) async throws -> KokoroEngine {
    let modelsDir = resolveModelsDir()
    let engine = KokoroEngine()
    print("Loading Kokoro from \(modelsDir.path) ...")
    try await engine.loadModels(from: modelsDir)
    try await engine.loadVoice(named: voice, in: modelsDir.appendingPathComponent("voices"))
    return engine
}

/// Mic → VAD → STT for exactly one utterance; returns the transcript.
func captureOneUtterance(transcriber: any VoiceTranscriber) async throws -> String {
    let mic = MicCapture()
    let vad = EnergyVAD(config: VADConfig())
    let frames = try mic.start()
    defer { mic.stop() }

    var utteranceOpen = false
    for await frame in frames {
        if utteranceOpen {
            await transcriber.append(frame.buffer)
        }
        switch vad.process(rms: frame.rms, frameDuration: frame.duration) {
        case .speechStart:
            guard let format = mic.format else { continue }
            try await transcriber.begin(format: format)
            await transcriber.append(frame.buffer)
            utteranceOpen = true
            print("  (hearing you…)")
        case .speechEnd:
            return try await transcriber.finish()
        case .discardedNoise:
            await transcriber.cancel()
            utteranceOpen = false
            print("  (too short — try again)")
        case .none:
            break
        }
    }
    throw TranscriberError.noSpeech
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail(usage)
}
arguments.removeFirst()

// Top-level code is async in Swift 5.5+ — awaiting directly avoids the
// classic CLI deadlock where a MainActor-inherited Task waits on a blocked
// main thread.
do {
    switch command {
        case "pronounce":
            let text = arguments.joined(separator: " ")
            guard !text.isEmpty else { fail("Nothing to trace. Usage: pronounce <text>") }
            let engine = try await loadedEngine(voice: "af_heart")
            let report = try await engine.pronunciationReport(for: text)
            print(report.table)
            if !report.concerns.isEmpty {
                print("\n⚠️ needs attention: \(report.concerns.map(\.word).joined(separator: ", "))")
            }

        case "g2p-validate":
            let sample = Int(flagValue(&arguments, "--sample") ?? "") ?? 500
            let seed = UInt64(flagValue(&arguments, "--seed") ?? "") ?? 42
            let engine = try await loadedEngine(voice: "af_heart")
            print("Validating neural G2P against \(sample) cache pairs (seed \(seed))…")
            let summaries = await engine.validateG2P(sampleCount: sample, seed: seed)
            for line in summaries { print(line) }

        case "speak":
            let voice = flagValue(&arguments, "--voice") ?? "af_heart"
            let styleName = flagValue(&arguments, "--style") ?? "neutral"
            let stream = boolFlag(&arguments, "--stream")
            let trace = boolFlag(&arguments, "--trace")
            guard let selection = SpeechStyleSelection(rawValue: styleName) else {
                fail("Unknown style '\(styleName)'. Options: \(SpeechStyleSelection.allCases.map(\.rawValue).joined(separator: " "))")
            }
            let text = arguments.joined(separator: " ")
            guard !text.isEmpty else { fail("Nothing to say. Usage: speak <text>") }

            let engine = try await loadedEngine(voice: voice)
            if trace {
                let report = try await engine.pronunciationReport(for: text)
                print(report.table)
            }
            if stream {
                // Exercise the LLM-token path: feed the text in growing slices.
                let speaker = KokoroStreamSpeaker(engine: engine, style: selection.style)
                let events = await speaker.events()
                let watcher = Task {
                    for await event in events { print("  [speaker] \(event)") }
                }
                var accumulated = ""
                for word in text.split(separator: " ") {
                    accumulated += (accumulated.isEmpty ? "" : " ") + word
                    await speaker.feed(accumulated)
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                await speaker.flush()
                watcher.cancel()
            } else {
                try await engine.speak(text, style: selection.style)
            }
            print("Done.")

        case "sewn-speak":
            let voiceID = flagValue(&arguments, "--voice") ?? VoiceCharacter.marie.id
            let base = flagValue(&arguments, "--url") ?? "http://127.0.0.1:8080"
            let stream = boolFlag(&arguments, "--stream")
            let text = arguments.joined(separator: " ")
            guard !text.isEmpty else { fail("Nothing to say. Usage: sewn-speak <text>") }
            guard let baseURL = URL(string: base) else { fail("Bad --url: \(base)") }

            let character = VoiceCharacter.named(voiceID)
            // Token read fresh per request (sign-in can land mid-reply).
            let sewn = SewnTTSEngine(baseURL: baseURL, character: character) {
                ProcessInfo.processInfo.environment["SEWN_TOKEN"]
            }
            // No Kokoro fallback; a Sewn drop must throw.
            await sewn.beginUtterance()
            let speaker = KokoroStreamSpeaker(synthesizer: sewn)
            let events = await speaker.events()
            let watcher = Task {
                for await event in events {
                    if case .chunkScheduled(let chunk) = event {
                        let emotion = EmotionClassifier.classify(
                            chunk, allowed: character.emotions)
                        print("  [speaker] scheduled (\(emotion.rawValue)): \(chunk.prefix(60))")
                    } else {
                        print("  [speaker] \(event)")
                    }
                }
            }
            if stream {
                // Exercise the LLM-token path: feed the text in growing slices,
                // which is how a streamed reply actually reaches the speaker.
                var accumulated = ""
                for word in text.split(separator: " ") {
                    accumulated += (accumulated.isEmpty ? "" : " ") + word
                    _ = await speaker.feed(accumulated)
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            } else {
                _ = await speaker.feed(text)
            }
            _ = await speaker.flush()
            watcher.cancel()
            print("spoke as \(await sewn.lastEmotion.rawValue) at \(await sewn.sampleRate) Hz")

        case "voices":
            let modelsDir = resolveModelsDir()
            let voices = KokoroEngine.availableVoices(in: modelsDir)
            print(voices.isEmpty ? "No voices found." : voices.joined(separator: "\n"))

        case "mic-levels":
            let seconds = Double(flagValue(&arguments, "--seconds") ?? "") ?? .infinity
            print("Listening\(seconds.isFinite ? " for \(Int(seconds))s" : " — Ctrl-C to stop"). Speak to see the bars move.")
            fflush(stdout)
            let mic = MicCapture()
            let frames = try mic.start()
            let deadline = Date().addingTimeInterval(seconds)
            var counter = 0
            for await frame in frames {
                if Date() > deadline { mic.stop(); break }
                counter += 1
                guard counter % 4 == 0 else { continue }  // ~12 Hz
                let bars = String(repeating: "█", count: Int(min(frame.rms * 400, 60)))
                print(String(format: "rms %.4f %@", frame.rms, bars))
                fflush(stdout)
            }

        case "vad":
            let seconds = Double(flagValue(&arguments, "--seconds") ?? "") ?? .infinity
            print("Endpointing\(seconds.isFinite ? " for \(Int(seconds))s" : " — Ctrl-C to stop"). Speak; silence closes the utterance.")
            fflush(stdout)
            let mic = MicCapture()
            let vad = EnergyVAD(config: VADConfig())
            let frames = try mic.start()
            let deadline = Date().addingTimeInterval(seconds)
            for await frame in frames {
                if Date() > deadline { mic.stop(); break }
                switch vad.process(rms: frame.rms, frameDuration: frame.duration) {
                case .speechStart:
                    print("▶ speechStart")
                case .speechEnd(let duration):
                    print(String(format: "■ speechEnd  %.2fs voiced", duration))
                case .discardedNoise:
                    print("· discarded (too short)")
                case .none:
                    break
                }
            }

        case "stt":
            let transcriber: any VoiceTranscriber = AppleSpeechTranscriber()
            print("Speak one utterance; silence ends it.")
            let text = try await captureOneUtterance(transcriber: transcriber)
            print("transcript: \(text)")

        case "loop":
            let voice = flagValue(&arguments, "--voice") ?? "af_heart"
            let transcriber: any VoiceTranscriber = AppleSpeechTranscriber()
            let engine = try await loadedEngine(voice: voice)
            print("Echo mode — Mary repeats what you say. Ctrl-C to stop.")
            while true {
                let text = try await captureOneUtterance(transcriber: transcriber)
                print("you said: \(text)")
                try await engine.speak(text)
            }

        case "wake":
            print("Standing by — say \u{201C}Hey Mary\u{201D} (or \u{201C}Hey Mary, <request>\u{201D}). Ctrl-C to stop.")
            fflush(stdout)
            let listener = WakeWordListener()
            let events = await listener.events()
            try await listener.start()
            for await event in events {
                switch event {
                case .wake(let remainder):
                    if let remainder {
                        print("[wake] remainder: \(remainder)")
                    } else {
                        print("[wake] bare")
                    }
                case .unavailable(let reason):
                    print("[wake] unavailable: \(reason)")
                }
                fflush(stdout)
            }

        default:
            print("'\(command)' is not wired up yet.\n")
            print(usage)
            exit(1)
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
