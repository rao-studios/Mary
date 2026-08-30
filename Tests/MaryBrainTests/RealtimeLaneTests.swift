//
//  RealtimeLaneTests.swift
//  MaryBrainTests
//
//  WHAT: Lane-A selection and realtime fallback rules against scripted providers.
//  OUT:  Dual-lane realtime path
//  PIN:  Classic DualLane remains the wired fallback
//

import MaryVoice
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct RealtimeLaneTests {

    // MARK: - Scripted collaborators

    final class ScriptedRealtime: SeerRealtimeProviding, @unchecked Sendable {
        struct Script {
            var events: [SeerChatEvent] = []
            var error: Error?
        }

        private let lock = NSLock()
        var ready = true
        private var scripts: [Script]
        private(set) var calls = 0

        init(scripts: [Script]) {
            self.scripts = scripts
        }

        func isReady() async -> Bool { ready }

        func streamTurn(
            messages: [SeerChatMessage], instructions: String?
        ) -> AsyncThrowingStream<SeerChatEvent, Error> {
            lock.lock()
            calls += 1
            let script = scripts.isEmpty ? Script() : scripts.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for event in script.events { continuation.yield(event) }
                if let error = script.error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    final class ScriptedSeer: SeerChatProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [[SeerChatEvent]]
        private(set) var calls = 0

        init(scripts: [[SeerChatEvent]]) {
            self.scripts = scripts
        }

        func isReady() async -> Bool { true }
        func ownerID() async -> String? { "owner-test" }

        func stream(
            messages: [SeerChatMessage], instructions: String?
        ) -> AsyncThrowingStream<SeerChatEvent, Error> {
            lock.lock()
            calls += 1
            let script = scripts.isEmpty ? [] : scripts.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for event in script { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    final class NoopEngine: InferenceEngine, @unchecked Sendable {
        let displayName = "noop"
        func warmup() async throws {}
        func stream(system: String, history: [BrainTurn], skills: [ModelSkillSchema]) -> AsyncThrowingStream<EngineEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.text("NOOP"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    struct TestError: Error {}

    private func makeBrain(
        realtime: ScriptedRealtime?,
        classic: ScriptedSeer
    ) async -> MaryBrain {
        let brain = MaryBrain(engine: NoopEngine())
        await brain.setSeerChat(classic)
        if let realtime {
            await brain.setSeerRealtime(realtime)
        }
        return brain
    }

    private func collect(_ brain: MaryBrain, _ text: String) async throws -> [BrainEvent] {
        var events: [BrainEvent] = []
        for try await event in brain.respond(to: text) {
            events.append(event)
        }
        return events
    }

    private func signature(_ events: [BrainEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .token:                       return "token"
            case .skillInvocation:             return "skillInvocation"
            case .skillResult:                 return "skillResult"
            case .contribution:                return "contribution"
            case .completed:                   return "completed"
            case .autoMemoryTriggered:         return "autoMemory"
            case .speechSource(.server):       return "source:server"
            case .speechSource(.local):        return "source:local"
            case .audioChunk:                  return "audio"
            case .retractSpeech:               return "retract"
            // Identity events are transport, not rhythm — invisible to the
            // signature so every pinned ordering stays untouched.
            case .turnBegan, .routineDetached, .exchangeSuperseded: return nil
            }
        }
    }

    private func tokenText(_ events: [BrainEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .token(let token) = event { text += token }
        }
    }

    private func fullText(_ events: [BrainEvent]) -> String? {
        for event in events {
            if case .completed(let text) = event { return text }
        }
        return nil
    }

    // MARK: - Rule: server marker precedes the first forwarded event

    @Test func serverMarkerPrecedesFirstRealtimeEvent() async throws {
        let realtime = ScriptedRealtime(scripts: [.init(events: [
            .phase("opening"),
            .token("Hi. "),
            .audio(pcm: Data([0, 0, 0, 0]), sampleRate: 24_000),
            .phase("grounded"),
            .token("Grounded rest."),
        ])])
        let classic = ScriptedSeer(scripts: [])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        let sig = signature(events)

        let serverIdx = try #require(sig.firstIndex(of: "source:server"))
        let firstToken = try #require(sig.firstIndex(of: "token"))
        let firstAudio = try #require(sig.firstIndex(of: "audio"))
        #expect(serverIdx < firstToken)
        #expect(serverIdx < firstAudio)
        #expect(tokenText(events) == "Hi. Grounded rest.")
        #expect(fullText(events) == "Hi. Grounded rest.")
        // Rule 4: narration handed back before the turn closes.
        let localIdx = try #require(sig.lastIndex(of: "source:local"))
        #expect(localIdx > firstToken)
        #expect(classic.calls == 0)
    }

    // MARK: - Rule 2: pre-stream failure reruns classic, indistinguishably

    @Test func preStreamFailureFallsBackToClassicWithNoMarkers() async throws {
        let realtime = ScriptedRealtime(scripts: [.init(error: TestError())])
        let classic = ScriptedSeer(scripts: [[.token("Classic reply.")]])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        let sig = signature(events)
        #expect(!sig.contains("source:server"))
        #expect(!sig.contains("source:local"))
        #expect(!sig.contains("audio"))
        #expect(fullText(events) == "Classic reply.")
        #expect(realtime.calls == 1)
        #expect(classic.calls == 1)
    }

    @Test func notReadyRealtimeUsesClassicWithoutCalling() async throws {
        let realtime = ScriptedRealtime(scripts: [])
        realtime.ready = false
        let classic = ScriptedSeer(scripts: [[.token("Classic reply.")]])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        #expect(fullText(events) == "Classic reply.")
        #expect(realtime.calls == 0)
        #expect(classic.calls == 1)
    }

    // MARK: - Rule 3: mid-stream failure keeps text, hands voice back, notices

    @Test func midStreamFailureKeepsTextAndSpeaksNoticeLocally() async throws {
        let realtime = ScriptedRealtime(scripts: [.init(
            events: [.token("Partial thought")],
            error: TestError()
        )])
        let classic = ScriptedSeer(scripts: [])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        let sig = signature(events)

        // The switch back to local precedes the dropped-connection notice.
        let localIdx = try #require(sig.firstIndex(of: "source:local"))
        let full = try #require(fullText(events))
        #expect(full.hasPrefix("Partial thought"))
        #expect(full.contains("the Seer connection dropped"))
        let noticeTokenIdx = try #require(events.indices.last { index in
            if case .token(let text) = events[index] { return text.contains("connection dropped") }
            return false
        })
        #expect(localIdx < noticeTokenIdx)
        // Classic did NOT rerun — mid-stream failures never replay the turn.
        #expect(classic.calls == 0)
    }

    // MARK: - tts.failed hands narration back mid-turn

    @Test func ttsFailedSwitchesToLocalAndSuppressesTrailingMarker() async throws {
        let realtime = ScriptedRealtime(scripts: [.init(events: [
            .token("Server-voiced. "),
            .ttsFailed,
            .token("Locally-voiced rest."),
        ])])
        let classic = ScriptedSeer(scripts: [])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        let sig = signature(events)

        let localIdx = try #require(sig.firstIndex(of: "source:local"))
        let lastTokenIdx = try #require(sig.lastIndex(of: "token"))
        #expect(localIdx < lastTokenIdx)
        // Exactly one hand-back: the rule-4 trailing marker is skipped once
        // the lane already returned narration to the local voice.
        #expect(sig.filter { $0 == "source:local" }.count == 1)
        #expect(fullText(events) == "Server-voiced. Locally-voiced rest.")
    }

    // MARK: - Contribution and auto-memory ride through unchanged

    @Test func contributionAndAutoMemoryForwardedFromRealtimeLane() async throws {
        let contribution = SeerContribution(
            owners: [.init(totemID: "t1", ownerID: "o1", spans: [.init(lower: 0, upper: 4)])])
        let realtime = ScriptedRealtime(scripts: [.init(events: [
            .token("Reply."),
            .contribution(contribution),
            .autoMemory(true),
        ])])
        let classic = ScriptedSeer(scripts: [])
        let brain = await makeBrain(realtime: realtime, classic: classic)

        let events = try await collect(brain, "hello")
        let sig = signature(events)
        #expect(sig.contains("contribution"))
        #expect(sig.contains("autoMemory"))
        let completedIdx = try #require(sig.firstIndex(of: "completed"))
        let contributionIdx = try #require(sig.firstIndex(of: "contribution"))
        #expect(contributionIdx < completedIdx)
    }
}
