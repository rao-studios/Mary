//
//  BrainFakes.swift
//  MaryBrainTests
//
//  WHAT: Scripted engine / Seer / dispatcher shared by turn-loop suites.
//  OUT:  ScriptedEngine, ScriptedSeer, table dispatcher
//

//
//  BrainFakes.swift
//  MaryBrainTests
//
//  WHAT: Scripted engine / Seer / dispatcher shared by turn-loop suites.
//  OUT:  ScriptedEngine, ScriptedSeer, table dispatcher
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

enum BrainFakes {
    final class ScriptedSeer: SeerChatProviding, @unchecked Sendable {
        struct Script {
            var events: [SeerChatEvent] = []
            var error: Error?
            /// Yield events, then stay open until cancelled (barge-in tests).
            var hangAtEnd = false
        }

        private let lock = NSLock()
        var ready = true
        private var scripts: [Script]
        private(set) var calls: [(messages: [SeerChatMessage], instructions: String?)] = []

        init(scripts: [Script]) {
            self.scripts = scripts
        }

        /// Lock-guarded value copy — the only way a test body may read
        /// `calls`: a detached routine can still be appending when an
        /// assertion runs, and an unguarded read of live storage tears count
        /// against buffer (the suite's old signal-5 crash).
        func callsSnapshot() -> [(messages: [SeerChatMessage], instructions: String?)] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func isReady() async -> Bool { ready }
        func ownerID() async -> String? { "owner-test" }

        func stream(
            messages: [SeerChatMessage], instructions: String?
        ) -> AsyncThrowingStream<SeerChatEvent, Error> {
            lock.lock()
            calls.append((messages, instructions))
            let script = scripts.isEmpty ? Script() : scripts.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for event in script.events { continuation.yield(event) }
                if let error = script.error {
                    continuation.finish(throwing: error)
                } else if !script.hangAtEnd {
                    continuation.finish()
                }
                continuation.onTermination = { _ in }
            }
        }
    }

    final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
        struct Round {
            var text: String = ""
            var calls: [ModelSkillInvocation] = []
        }

        let displayName = "scripted"
        private let lock = NSLock()
        private var rounds: [Round]
        private(set) var requests: [(historyRoles: [BrainTurn.Role], system: String)] = []
        /// Every history TEXT the orchestrator was ever shown — the surface
        /// the RAG-isolation guardrail inspects. Recorded separately so the
        /// existing `requests` shape stays pinned as-is.
        private(set) var historyTexts: [[String]] = []

        init(rounds: [Round]) {
            self.rounds = rounds
        }

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func requestsSnapshot() -> [(historyRoles: [BrainTurn.Role], system: String)] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func historyTextsSnapshot() -> [[String]] {
            lock.lock(); defer { lock.unlock() }
            return historyTexts
        }

        func warmup() async throws {}

        func stream(system: String, history: [BrainTurn], skills: [ModelSkillSchema]) -> AsyncThrowingStream<EngineEvent, Error> {
            lock.lock()
            requests.append((history.map(\.role), system))
            historyTexts.append(history.map(\.text))
            let round = rounds.isEmpty ? Round() : rounds.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                if !round.text.isEmpty { continuation.yield(.text(round.text)) }
                for call in round.calls { continuation.yield(.skillInvocation(call)) }
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    final class StubDispatcher: AbilityDispatching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var dispatched: [String] = []
        var results: [String: String] = [:]
        /// Tools the brain should treat as read-only (skipped from the Totem
        /// deposit). Configured before a turn; read under the lock.
        var readOnlyTools: Set<String> = []
        /// Tools whose outcome is a fire-and-forget ack (deferred), also
        /// skipped from the deposit.
        var deferredTools: Set<String> = []
        /// Tools declaring `.none` — nothing happened worth remembering.
        var unrememberedTools: Set<String> = []
        /// Tools declaring `.stateSnapshot` — their result describes the
        /// focused document as it now stands.
        var stateSnapshotTools: Set<String> = []
        /// The plugin owner for Skills that need archive attribution.
        var toolWorlds: [String: AmbientWorld] = [:]
        /// Tools whose dispatch reports ok=false (the spoken-failure rhythm).
        var failingTools: Set<String> = []
        /// Tools whose dispatch reports `foundNothing: true` — `ok: true` by
        /// this codebase's own convention (the read ran; there was nothing to
        /// find), so this is distinct from `failingTools`.
        var foundNothingTools: Set<String> = []
        /// Directly settable — flipped by tests and by confirm/cancel dispatch.
        var pending = false
        /// Optional packaged registry for archive/projection integration tests.
        var snapshotOverride: AbilityRuntimeSnapshot?
        /// FETCH-FIRST: what a pre-read answers. Nil (the default) means "no
        /// targeted read in view", which is what every pre-existing test gets
        /// — so their turns stay byte-identical.
        var namedPartPassage: String?
        /// Every phrase fetch-first actually asked for. Empty on an ordinary
        /// turn is the pin that says ordinary turns take no extra read.
        private(set) var namedPartRequests: [String] = []
        /// THE DESIGN VETO'S SCRIPTED ANSWERS. Empty by default so every
        /// pre-existing turn is untouched (nil role arms nothing).
        var applicationProfilesOverride: [ApplicationProfile] = []
        var focusedApplicationIDOverride: String?
        private(set) var armedDesignSurfaceApplications: [String] = []

        var schemas: [ModelSkillSchema] {
            [ModelSkillSchema(name: "probe", description: "", parameters: [])]
        }

        var abilitySnapshot: AbilityRuntimeSnapshot {
            snapshotOverride ?? .empty
        }

        func skillReference(for invocationName: String) -> AbilitySkillReference {
            snapshotOverride?.reference(forInvocation: invocationName)
                ?? fixtureAbilityReference(invocationName)
        }

        var hasPendingSkillConfirmation: Bool {
            lock.lock(); defer { lock.unlock() }
            return pending
        }

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func dispatchedSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return dispatched
        }

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func armedDesignSurfaceApplicationsSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return armedDesignSurfaceApplications
        }

        func beginTurn() {}

        func isReadOnly(_ skillName: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return readOnlyTools.contains(skillName)
        }

        func world(ofSkill skillName: String) -> AmbientWorld? {
            lock.lock(); defer { lock.unlock() }
            return toolWorlds[skillName]
        }

        func readNamedPart(_ phrase: String) async -> String? {
            lock.lock(); defer { lock.unlock() }
            namedPartRequests.append(phrase)
            return namedPartPassage
        }

        func namedPartRequestsSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return namedPartRequests
        }

        var applicationProfiles: [ApplicationProfile] {
            lock.lock(); defer { lock.unlock() }
            return applicationProfilesOverride
        }

        var focusedApplicationID: String? {
            lock.lock(); defer { lock.unlock() }
            return focusedApplicationIDOverride
        }

        func dispatch(name: String, argumentsJSON: String, runID: String? = nil) async -> SkillOutcome {
            lock.lock()
            dispatched.append(name)
            if name == AbilityRuntime.confirmSkillName || name == AbilityRuntime.cancelSkillName {
                pending = false
            }
            let summary = results[name] ?? "ok"
            if summary.hasPrefix("CONFIRM:") { pending = true }
            let deferred = deferredTools.contains(name)
            let ok = !failingTools.contains(name)
            let foundNothing = foundNothingTools.contains(name)
            let policy: ArchivePolicy = unrememberedTools.contains(name)
                ? .none
                : (stateSnapshotTools.contains(name) ? .stateSnapshot : .episodic)
            lock.unlock()
            let outcome = SkillOutcome(
                ok: ok, summary: summary,
                // The real runtime parks a CONFIRM with `.requested`; the stub
                // mirrors that so the lane's requested flag is exercised here.
                status: summary.hasPrefix("CONFIRM:") ? .requested : nil,
                deferred: deferred, archivePolicy: policy, foundNothing: foundNothing)
            guard let snapshotOverride else { return outcome }
            return AbilityRuntime.applyingTotemArchivePolicy(
                outcome,
                reference: snapshotOverride.reference(forInvocation: name),
                snapshot: snapshotOverride)
        }
    }
}
