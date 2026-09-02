//
//  ProbeSeer.swift
//  Mary
//
//  WHAT: Headless full-stack Seer turn (servers, sign-in, dual-lane brain).
//  OUT:  contribution + timing. CLI: swift run Mary --probe-seer "…" [--follow] [--then]
//  PIN:  Always wires Seer, even if Brain card says on-device.
//

import MaryBrain
import MaryVoice
import Foundation
import MaryRuntime

enum ProbeSeer {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-seer")
    }

    static func start() {
        Task.detached {
            let code = await run()
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--probe-seer"),
              flagIndex + 1 < arguments.count else {
            print("Usage: Mary --probe-seer <text> [--engine mistral] [--transport classic|realtime] [--speak]")
            return 1
        }
        let text = arguments[flagIndex + 1]
        let speak = arguments.contains("--speak")
        let follow = arguments.contains("--follow")
        var thenText: String?
        if let thenIndex = arguments.firstIndex(of: "--then"), thenIndex + 1 < arguments.count {
            thenText = arguments[thenIndex + 1]
        }
        var engineName = "mistral-api"
        if let engineIndex = arguments.firstIndex(of: "--engine"), engineIndex + 1 < arguments.count {
            engineName = arguments[engineIndex + 1]
        }
        var chatModel = ""
        if let modelIndex = arguments.firstIndex(of: "--chat-model"), modelIndex + 1 < arguments.count {
            chatModel = arguments[modelIndex + 1]
        }
        var transport = SeerTransportChoice.classic
        if let transportIndex = arguments.firstIndex(of: "--transport"), transportIndex + 1 < arguments.count {
            guard let parsed = SeerTransportChoice(rawValue: arguments[transportIndex + 1]) else {
                print("Unknown transport '\(arguments[transportIndex + 1])' — use classic or realtime.")
                return 1
            }
            transport = parsed
        }

        DotEnv.loadMaryEnvironment()

        // 1. Local stack — the same appliers the app boot uses (default
        // config: fresh State() carries all the ServerSpec defaults).
        var defaults = ConfigService.Center.State()
        defaults.seerChatModel = chatModel
        let nodeID = TotemNodeIdentity.adoptOrMint(configured: defaults.totemNodeID)
        await MaryRuntime.applyServers(config: defaults, nodeID: nodeID)
        print("[stack] bringing servers up…")
        if let failure = await MaryRuntime.localStack.ensureRunning() {
            print("[stack] FAILED: \(failure)")
            return 1
        }
        let policyPushed = await TotemGraphPolicy.push(totemPort: defaults.totemPort)
        print("[graph] policy push \(policyPushed ? "ok" : "failed")")

        // 2. Sign in.
        if let error = await MaryRuntime.applySeerAccount(
            email: defaults.seerEmail,
            password: defaults.seerPassword,
            seerPort: defaults.seerPort) {
            print("[auth] \(error)")
            return 1
        }
        let owner = await MaryRuntime.seerSession.userID ?? "?"
        print("[auth] signed in as \(owner)")

        // 3. Brain wiring — same shape the app boot uses.
        let engine: any InferenceEngine
        switch engineName {
        case "mistral": engine = MaryLocalEngine()
        default:
            print("Unknown engine '\(engineName)' — use tinker, mistral, or mistral-api.")
            return 1
        }
        if speak {
            if let error = await MaryRuntime.bootKokoro(voice: "af_heart") {
                print("(kokoro unavailable: \(error) — continuing text-only)")
            }
            if let notice = await MaryRuntime.applyTTSBackend(
                .seer, hostedVoice: VoiceCharacter.marie.id) {
                print("(\(notice))")
            } else {
                print("[tts] speaking through Seer /v1/speak")
            }
        }
        await MaryRuntime.brain.setEngine(engine)
        let projects = ["mary": FileManager.default.currentDirectoryPath]
        await MaryRuntime.installBrainConfiguration(projects: projects)
        // THE PROBE ALWAYS WIRES SEER, whatever the Brain card says — it
        // exists to exercise the server, so honouring a stored "on device"
        // would make it probe nothing.
        await MaryRuntime.connectSeerToBrain(
            chat: true, archiving: true, stackEnabled: true)
        await MaryRuntime.applySeerTransport(transport)
        print("[transport] \(transport.rawValue)")

        // Subscribe BEFORE the turn so routineStarted can't be missed — the
        // stream buffers from creation, so consuming after the turns is safe.
        let proactiveStream = follow ? MaryRuntime.brain.proactiveEvents() : nil

        do {
            try await MaryRuntime.brain.warmup()
            try await runTurn(text: text, speak: speak)

            if let thenText {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await runTurn(text: thenText, speak: speak)
            }

            if let proactiveStream {
                // Consume inline in a group child (for-await is cancellable —
                // never race Task.value in a group; its await-all pins to the
                // uncancellable child).
                let finished = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for await event in proactiveStream {
                            switch event {
                            case .routineStarted:
                                print("\n[routine] started")
                            case .skillInvocation(let reference, _, _, _):
                                print("[routine ability] \(reference.displayLabel)")
                            case .skillResult(let record, _):
                                print("[routine result] \(record.action.skill.displayLabel): \(record.summary.prefix(160))")
                            case .followUpToken:
                                break
                            case .routineProgress(let line, _):
                                print("[routine] \(line)")
                            case .followUpCompleted(let fullText, _):
                                print("[follow-up] \(fullText)")
                                return true
                            case .routineCancelled(_, let acknowledgement, _):
                                print("[routine] cancelled — \(acknowledgement)")
                                return true
                            case .routineSettled:
                                print("[routine] settled — nothing to report")
                                return true
                            case .ambientUtterance(let line, let candidateID):
                                print("[ambient] \(line)  (candidate \(candidateID.uuidString.prefix(8)))")
                            case .autoMemoryTriggered:
                                print("[auto-memory] follow-up folded the conversation to the final exchange")
                            }
                            fflush(stdout)
                        }
                        return false
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 180_000_000_000)
                        return false
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
                if !finished { print("[follow] timed out waiting for the routine") }
            }
            print("[done] (servers left running)")
            return 0
        } catch {
            print("\nError: \(error.localizedDescription)")
            return 1
        }
    }

    private static func runTurn(text: String, speak: Bool) async throws {
        print("[user] \(text)")
        print("[mary] ", terminator: "")
        var accumulated = ""
        let submitStart = Date()
        var firstTokenAt: Date?
        var firstAudioAt: Date?
        // Same routing machine as VoicePipeline/TextTurnRunner; armed only when
        // audio output is requested. Timing stamps stay probe-side.
        var router: SpeechRouter? = speak ? SpeechRouter(speaker: MaryRuntime.speaker) : nil
        let events = MaryRuntime.brain.respond(to: text)
        for try await event in events {
            switch event {
            case .token(let token):
                if firstTokenAt == nil { firstTokenAt = Date() }
                accumulated += token
                print(token, terminator: "")
                fflush(stdout)
                await router?.consumeToken(accumulated: accumulated)
            case .speechSource(let source):
                router?.consumeSpeechSource(source, accumulated: accumulated)
            case .retractSpeech:
                // Same routing machine as VoicePipeline/TextTurnRunner: the ear
                // is rewound, the printed transcript keeps what it printed.
                await router?.consumeRetractSpeech(accumulated: accumulated)
            case .audioChunk(let pcm, let sampleRate):
                if firstAudioAt == nil { firstAudioAt = Date() }
                await router?.consumeAudioChunk(pcm, sampleRate: sampleRate)
            case .skillInvocation(let reference, let argumentsJSON, _):
                print("\n[ability] \(reference.displayLabel) \(argumentsJSON)")
            case .skillResult(let record):
                print("[ability-result] \(record.action.skill.displayLabel): \(record.summary.prefix(200))")
            case .contribution(let json):
                if let contribution = SeerContribution.fromJSON(json) {
                    print("\n[contribution] \(contribution.owners.count) owner(s)")
                    for ownerEntry in contribution.owners {
                        print("  totem=\(ownerEntry.totemID.prefix(8))… royalty=\(ownerEntry.royalty) spans=\(ownerEntry.spans.map { "\($0.lower)..\($0.upper)" }.joined(separator: ",")) docs=\(ownerEntry.documentIDs.count)")
                    }
                }
            case .autoMemoryTriggered:
                print("\n[auto-memory] conversation folded to the final exchange")
            case .completed:
                break
            case .turnBegan, .routineDetached:
                // Identity events — transcript concerns; the probe prints
                // the rhythm, not the anchoring.
                break
            case .exchangeSuperseded:
                print("\n[superseded] previous exchange removed")
            }
        }
        print("")
        let totalMs = Int(Date().timeIntervalSince(submitStart) * 1000)
        let ttftMs = firstTokenAt.map { Int($0.timeIntervalSince(submitStart) * 1000) }
        let firstAudioMs = firstAudioAt.map { Int($0.timeIntervalSince(submitStart) * 1000) }
        print("[timing] submit→first-token=\(ttftMs.map { "\($0)ms" } ?? "n/a")  submit→first-audio=\(firstAudioMs.map { "\($0)ms" } ?? "n/a")  submit→completed=\(totalMs)ms")
        if let router {
            await router.finish()
        }
    }
}
