//
//  ProbeChat.swift
//  Mary
//
//  WHAT: Headless one-turn chat (same brain/speaker, no window).
//  OUT:  streamed tokens + [metrics]. CLI: swift run Mary --probe-chat "…" --engine …
//

import MaryBrain
import MaryPlugin
import MaryVoice
import Foundation
import MaryRuntime

enum ProbeChat {

    // Check if probe chat should run
    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-chat")
    }

    static func start() {
        // Detached: the main thread parks in RunLoop.run() below and must not
        // carry actor work (the classic CLI MainActor deadlock).
        Task.detached {
            let code = await run()
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--probe-chat"),
              flagIndex + 1 < arguments.count else {
            print("Usage: Mary --probe-chat <text> [--engine mistral] [--speak] [--tts kokoro|mistral]")
            return 1
        }
        let text = arguments[flagIndex + 1]
        let speak = arguments.contains("--speak")
        // DEFAULT TO AN ENGINE THIS SWITCH ACTUALLY HAS. It read
        // "mistral-api", which no case matched, so a bare `--probe-chat`
        // always exited 1 on the usage line below.
        var engineName = "mistral"
        if let engineIndex = arguments.firstIndex(of: "--engine"), engineIndex + 1 < arguments.count {
            engineName = arguments[engineIndex + 1]
        }
        // The app's default TTS is Mistral; --tts kokoro forces on-device.
        var ttsBackend = TTSBackend.seer
        if let ttsIndex = arguments.firstIndex(of: "--tts"), ttsIndex + 1 < arguments.count {
            guard let parsed = TTSBackend(rawValue: arguments[ttsIndex + 1]) else {
                print("Unknown TTS backend '\(arguments[ttsIndex + 1])' — use kokoro or mistral.")
                return 1
            }
            ttsBackend = parsed
        }
        // --model overrides the engine's default id (MLX or hosted).
        var modelID: String?
        if let modelIndex = arguments.firstIndex(of: "--model"), modelIndex + 1 < arguments.count {
            modelID = arguments[modelIndex + 1]
        }

        DotEnv.loadMaryEnvironment()

        let engine: any InferenceEngine
        switch engineName {
        case "mistral": engine = MaryLocalEngine(modelID: modelID ?? MaryLocalEngine.defaultModelID)
        default:
            print("Unknown engine '\(engineName)' — use mistral (on-device MLX).")
            return 1
        }

        do {
            if speak {
                if let error = await MaryRuntime.bootKokoro(voice: "af_heart") {
                    print("(kokoro unavailable: \(error) — continuing text-only)")
                }
                if let notice = await MaryRuntime.applyTTSBackend(
                    ttsBackend, hostedVoice: VoiceCharacter.marie.id) {
                    print("(\(notice))")
                }
            }

            print("[\(engine.displayName)] warming up…")
            await MaryRuntime.brain.setEngine(engine)
            // Full activity loop, with the repo itself as a test project.
            let projects = ["mary": FileManager.default.currentDirectoryPath]
            await MaryRuntime.installBrainConfiguration(projects: projects)
            try await MaryRuntime.brain.warmup()

            print("[user] \(text)")
            print("[mary] ", terminator: "")
            var accumulated = ""
            let turnStart = Date()
            var firstEventAt: Date?
            let events = MaryRuntime.brain.respond(to: text)
            for try await event in events {
                switch event {
                case .token(let token):
                    if firstEventAt == nil { firstEventAt = Date() }
                    accumulated += token
                    print(token, terminator: "")
                    fflush(stdout)
                    if speak { await MaryRuntime.speaker.feed(accumulated) }
                case .skillInvocation(let reference, let argumentsJSON, _):
                    if firstEventAt == nil { firstEventAt = Date() }
                    print("\n[ability] \(reference.displayLabel) \(argumentsJSON)")
                case .skillResult(let record):
                    print("[ability-result] \(record.action.skill.displayLabel): \(record.summary)")
                case .contribution(let json):
                    print("\n[contribution] \(json)")
                case .autoMemoryTriggered:
                    print("\n[auto-memory] conversation folded to the final exchange")
                case .completed:
                    break
                case .speechSource, .audioChunk:
                    // Realtime-route events; ProbeChat runs engine-only turns.
                    break
                case .retractSpeech:
                    // The takeover is a SPEECH concern and this probe prints
                    // text: the transcript deliberately keeps what was written,
                    // so there is nothing here to rewind.
                    break
                case .turnBegan, .routineDetached:
                    // Identity events — transcript concerns; the probe
                    // prints the rhythm, not the anchoring.
                    break
                case .exchangeSuperseded:
                    print("\n[superseded] previous exchange removed")
                }
            }
            print("")
            // The engine-agnostic A/B line: whole turn including Skill results
            // executions — the numbers the user actually feels.
            let totalMs = Int(Date().timeIntervalSince(turnStart) * 1000)
            let ttft = firstEventAt.map { "\(Int($0.timeIntervalSince(turnStart) * 1000))ms" } ?? "-"
            print("[metrics] engine=\(engineName) ttft=\(ttft) total=\(totalMs)ms")
            if speak { await MaryRuntime.speaker.flush() }
            return 0
        } catch {
            print("\nError: \(error.localizedDescription)")
            return 1
        }
    }
}
