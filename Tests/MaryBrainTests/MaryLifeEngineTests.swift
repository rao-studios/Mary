//
//  MaryLifeEngineTests.swift
//  MaryBrainTests
//
//  WHAT: The idle engine's gates, its adapter cache, and its two modes.
//  OUT:  MaryLifeEngine
//  PIN:  Every pulse produces a decision, including the refusals — these
//        tests assert the REASON, not just the absence of an act.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

// MARK: - Fakes

private struct StaticSlots: LifeSlotProviding {
    var slots: [AbilityID: LifeLoRASlot]
    var reachable = true
    func adapters() async -> (slots: [AbilityID: LifeLoRASlot], reachable: Bool) {
        (slots, reachable)
    }
}

/// Slots that change between calls — a retrain, seen from the engine's side.
private final class MutableSlots: LifeSlotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [AbilityID: LifeLoRASlot]
    init(_ value: [AbilityID: LifeLoRASlot]) { self.value = value }
    func set(_ next: [AbilityID: LifeLoRASlot]) {
        lock.lock(); value = next; lock.unlock()
    }
    func adapters() async -> (slots: [AbilityID: LifeLoRASlot], reachable: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (value, true)
    }
}

private struct StaticConditions: LifeConditionsProviding {
    var value: LifeConditions
    func conditions() async -> LifeConditions { value }
}

private struct StaticWorld: LifeWorldProviding {
    var world: LifeWorld?
    func pulseWorld() async -> LifeWorld? { world }
}

private struct ScriptedSession: LifeAdapterSessioning {
    var actions: [BehavioralTrainingOutput.Action]
    var error: Error?
    func complete(
        input: BehavioralTrainingInput, schemaJSON: Data
    ) async throws -> LifeCompletion {
        if let error { throw error }
        return LifeCompletion(
            output: BehavioralTrainingOutput(actions: actions),
            forcedFraction: 0.5,
            promptTokens: 42)
    }
}

/// Counts how many distinct sessions the engine asked for — the reload rule.
private final class ScriptedMaker: LifeAdapterSessionMaking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var madeKeys: [String] = []
    var actions: [BehavioralTrainingOutput.Action] = []
    var completionError: Error?
    /// Set to refuse the load, the way a base-model mismatch does.
    var makeError: LifeEngineError?

    func makeSession(adapter: LifeAdapterRef) throws -> any LifeAdapterSessioning {
        lock.lock(); defer { lock.unlock() }
        if let makeError { throw makeError }
        madeKeys.append(adapter.sessionKey)
        return ScriptedSession(actions: actions, error: completionError)
    }

    func madeKeysSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return madeKeys
    }
}

private final class RecordingBehavior: BehavioralRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BehavioralEpisode] = []
    func append(_ episode: BehavioralEpisode) async {
        lock.lock(); stored.append(episode); lock.unlock()
    }
    func episodes() -> [BehavioralEpisode] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

// MARK: - Fixtures

private let anchor = Date(timeIntervalSince1970: 1_787_821_200)

private func slot(
    _ id: AbilityID,
    ready: Bool = true,
    cid: String = "cid-one",
    generation: Int = 1,
    modelID: String = "test-model"
) -> LifeLoRASlot {
    LifeLoRASlot(
        abilityID: id,
        generation: generation,
        pairCount: 24,
        artifactPath: "/tmp/life/\(id.rawValue)",
        schemaJSON: Data(#"{"root":{}}"#.utf8),
        ready: ready,
        trainedAt: anchor,
        training: false,
        modelID: modelID,
        cid: cid)
}

private func world(disciplines: [AbilityID] = [.writing]) -> LifeWorld {
    LifeWorld(
        input: BehavioralTrainingInput(
            query: "idle", ambientMode: "focusedWorld",
            ambientLead: "applications:textedit", factCount: 1,
            ambientSummary: "Essay — 1,840 characters"),
        leadDisciplines: disciplines,
        leadLabel: "TextEdit")
}

private func quiet(
    lastUserEpisodeAt: Date? = anchor.addingTimeInterval(-600),
    secondsSinceUserInput: TimeInterval? = 600
) -> LifeConditions {
    LifeConditions(
        isTurnInFlight: false,
        isSkillRunning: false,
        isWorkspaceIndexing: false,
        lastUserEpisodeAt: lastUserEpisodeAt,
        secondsSinceUserInput: secondsSinceUserInput,
        now: anchor)
}

private func typeAction(_ name: String = "type_at_cursor") -> BehavioralTrainingOutput.Action {
    BehavioralTrainingOutput.Action(
        intention: name,
        argumentsJSON: #"{"text":"hi"}"#,
        skillID: "writing.type-at-cursor",
        invocationName: name,
        disposition: "succeeded",
        summary: "typed")
}

@MainActor
private func makeEngine(
    slots: any LifeSlotProviding,
    conditions: LifeConditions = quiet(),
    world pulseWorld: LifeWorld? = world(),
    maker: ScriptedMaker,
    dispatcher: BrainFakes.StubDispatcher? = nil,
    behavior: BehavioralAssembler = BehavioralAssembler(),
    mode: LifeMode = .observe,
    config: LifeEngineConfig = LifeEngineConfig()
) -> MaryLifeEngine {
    MaryLifeEngine(
        slots: slots,
        conditions: StaticConditions(value: conditions),
        world: StaticWorld(world: pulseWorld),
        sessionMaker: maker,
        behavior: behavior,
        dispatcher: dispatcher,
        config: config,
        mode: mode,
        appVersion: "test",
        clock: { anchor })
}

// MARK: - Gates

@Suite struct LifeEngineGateTests {

    @Test func offRefusesBeforeAnythingElse() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker, mode: .off)
        let decision = await engine.pulseNow(dryRun: true)
        #expect(decision.outcome == .skipped)
        #expect(decision.skip == .modeOff)
        #expect(maker.madeKeysSnapshot().isEmpty)
    }

    @Test func anOpenTurnRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: LifeConditions(
                isTurnInFlight: true, lastUserEpisodeAt: nil,
                secondsSinceUserInput: 600, now: anchor),
            maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .turnInFlight)
    }

    @Test func aRunningSkillRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: LifeConditions(
                isSkillRunning: true, lastUserEpisodeAt: nil,
                secondsSinceUserInput: 600, now: anchor),
            maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .skillRunning)
    }

    @Test func indexingRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: LifeConditions(
                isWorkspaceIndexing: true, lastUserEpisodeAt: nil,
                secondsSinceUserInput: 600, now: anchor),
            maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .indexing)
    }

    @Test func aRecentTurnRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: quiet(lastUserEpisodeAt: anchor.addingTimeInterval(-10)),
            maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .userSpoke)
    }

    /// THE GATE THE OLD LOOP DID NOT HAVE. A conversation pause is not an
    /// idle machine: someone typing in the lead window is not away.
    @Test func recentTypingRefusesEvenWhenMaryHasNotBeenSpokenTo() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: quiet(lastUserEpisodeAt: nil, secondsSinceUserInput: 12),
            maker: ScriptedMaker())
        let decision = await engine.pulseNow()
        #expect(decision.skip == .userTyping)
        #expect(decision.detail.contains("12s ago"))
    }

    /// No HID source is not a claim that the machine is quiet, but it must
    /// not block either — the gate reports only what it knows.
    @Test func anUnknownInputClockDoesNotBlock() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: quiet(secondsSinceUserInput: nil),
            maker: maker)
        #expect(await engine.pulseNow().skip != .userTyping)
    }

    @Test func nothingInFrontRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            world: nil, maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .noLead)
    }

    @Test func noReadyAdapterRefuses() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing, ready: false)]),
            maker: ScriptedMaker())
        #expect(await engine.pulseNow().skip == .noReadyDiscipline)
    }

    /// A READY ADAPTER IS NOT A LICENCE TO USE IT ANYWHERE. The old loop fell
    /// back to any ready discipline, so a Writing adapter acted in Xcode.
    @Test func aReadyAdapterTheLeadDoesNotDeclareIsNotReachedFor() async {
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            world: world(disciplines: [.coding]),
            maker: ScriptedMaker())
        let decision = await engine.pulseNow()
        #expect(decision.skip == .leadHasNoDiscipline)
        #expect(decision.detail.contains("TextEdit"))
    }

    @Test func aMismatchedBaseModelRefusesTheAdapter() async {
        let maker = ScriptedMaker()
        maker.makeError = .modelMismatch(expected: "engine-model", got: "other-model")
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]), maker: maker)
        let decision = await engine.pulseNow()
        #expect(decision.skip == .modelMismatch)
        #expect(decision.detail.contains("other-model"))
    }
}

// MARK: - Deciding

@Suite struct LifeEngineDecisionTests {

    @Test func observeRecordsWhatItWouldDoAndDispatchesNothing() async {
        let maker = ScriptedMaker()
        maker.actions = [typeAction()]
        let dispatcher = BrainFakes.StubDispatcher()
        let recorder = RecordingBehavior()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker,
            dispatcher: dispatcher,
            behavior: BehavioralAssembler(recorder: recorder),
            mode: .observe)

        let decision = await engine.pulseNow(dryRun: false)

        #expect(decision.outcome == .proposed)
        #expect(decision.actionCount == 1)
        #expect(decision.inferenceMs >= 0)
        #expect(decision.promptTokens == 42)
        #expect(dispatcher.dispatchedSnapshot().isEmpty)
    }

    /// An effectful act with nobody watching is not a prediction the engine
    /// gets to make — it is held, recorded, and visible.
    @Test func actHoldsAnEffectfulSkillItCannotVouchFor() async {
        let maker = ScriptedMaker()
        maker.actions = [typeAction()]
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker, dispatcher: dispatcher, mode: .act)

        let decision = await engine.pulseNow(dryRun: false)

        #expect(decision.outcome == .proposed)
        #expect(dispatcher.dispatchedSnapshot().isEmpty)
        #expect(decision.detail.contains("held"))
    }

    @Test func actRunsAReadThatChangesNothing() async {
        let maker = ScriptedMaker()
        maker.actions = [typeAction("read_document")]
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["read_document"]
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker, dispatcher: dispatcher, mode: .act)

        let decision = await engine.pulseNow(dryRun: false)

        #expect(decision.outcome == .acted)
        #expect(dispatcher.dispatchedSnapshot() == ["read_document"])
    }

    /// A dry run is how a person watches the engine think. It must never be
    /// a way to make it act.
    @Test func aDryRunNeverDispatchesEvenInActMode() async {
        let maker = ScriptedMaker()
        maker.actions = [typeAction("read_document")]
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["read_document"]
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker, dispatcher: dispatcher, mode: .act)

        let decision = await engine.pulseNow(dryRun: true)

        #expect(decision.outcome == .proposed)
        #expect(dispatcher.dispatchedSnapshot().isEmpty)
    }

    @Test func restraintIsARecordedResultNotSilence() async {
        let maker = ScriptedMaker()
        maker.actions = []
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]), maker: maker)

        let decision = await engine.pulseNow()

        #expect(decision.outcome == .silent)
        #expect(decision.actionCount == 0)
        #expect(decision.detail == "nothing to do")
    }

    @Test func aFailedCompletionIsDroppedAndKept() async {
        struct Boom: Error {}
        let maker = ScriptedMaker()
        maker.completionError = Boom()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]), maker: maker)

        let decision = await engine.pulseNow()

        #expect(decision.outcome == .dropped)
        let snapshot = await engine.snapshot()
        #expect(snapshot.errorTail.count == 1)
    }

    /// The episode Life produces carries the proactive lane — the stamp the
    /// training policy filters on so the engine never learns from itself.
    @Test func theSealedEpisodeIsStampedProactive() async {
        let maker = ScriptedMaker()
        maker.actions = [typeAction()]
        let recorder = RecordingBehavior()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            maker: maker,
            behavior: BehavioralAssembler(recorder: recorder),
            mode: .observe)

        _ = await engine.pulseNow(dryRun: false)
        // The handoff is detached; give it a moment to land.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let episodes = recorder.episodes()
        #expect(episodes.count == 1)
        #expect(episodes.first?.provenance.lane == MaryLifeEngine.proactiveLane)
        #expect(episodes.first?.sealedReason == .completed)
        #expect(episodes.first?.output.actions.first?.disposition == .deferred)
    }
}

// MARK: - The adapter it holds

@Suite struct LifeEngineAdapterTests {

    /// A RETRAIN KEEPS THE PATH AND CHANGES THE WEIGHTS. Keying the session
    /// on the path alone held last generation's adapter until relaunch.
    @Test func aRetrainReloadsTheSessionEvenThoughThePathIsUnchanged() async {
        let maker = ScriptedMaker()
        let slots = MutableSlots([.writing: slot(.writing, cid: "gen-one")])
        let engine = await makeEngine(slots: slots, maker: maker)

        _ = await engine.pulseNow()
        slots.set([.writing: slot(.writing, cid: "gen-two", generation: 2)])
        _ = await engine.pulseNow()

        let keys = maker.madeKeysSnapshot()
        #expect(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test func anUnchangedAdapterIsLoadedOnce() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]), maker: maker)

        _ = await engine.pulseNow()
        _ = await engine.pulseNow()

        #expect(maker.madeKeysSnapshot().count == 1)
    }

    /// A RESIDENT ADAPTER PINS A COPY OF THE BASE MODEL. Most pulses refuse
    /// at a gate and never touch it, so holding it through a quiet afternoon
    /// costs gigabytes for nothing.
    @Test func anUnusedAdapterIsLetGoAfterAFewRefusedPulses() async {
        let maker = ScriptedMaker()
        let slots = MutableSlots([.writing: slot(.writing)])
        let engine = await makeEngine(
            slots: slots, maker: maker,
            config: LifeEngineConfig(idlePulsesBeforeUnload: 2))

        _ = await engine.pulseNow()
        #expect(await engine.snapshot().loadedAdapter != nil)

        // The lead goes away; the next pulses refuse before inference.
        slots.set([:])
        _ = await engine.pulseNow()
        _ = await engine.pulseNow()

        #expect(await engine.snapshot().loadedAdapter == nil)
    }

    @Test func aRefusedPulseDoesNotDropAnAdapterImmediately() async {
        let maker = ScriptedMaker()
        let slots = MutableSlots([.writing: slot(.writing)])
        let engine = await makeEngine(
            slots: slots, maker: maker,
            config: LifeEngineConfig(idlePulsesBeforeUnload: 4))

        _ = await engine.pulseNow()
        slots.set([:])
        _ = await engine.pulseNow()

        #expect(await engine.snapshot().loadedAdapter != nil)
    }

    @Test func theSnapshotNamesTheAdapterItIsHolding() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing, generation: 3)]),
            maker: maker)

        _ = await engine.pulseNow()
        let snapshot = await engine.snapshot()

        #expect(snapshot.loadedAdapter?.abilityID == .writing)
        #expect(snapshot.loadedAdapter?.generation == 3)
        #expect(snapshot.readyCount == 1)
    }
}

// MARK: - Being watched

@Suite struct LifeEngineMonitoringTests {

    @Test func everyPulseIsKeptNewestFirst() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [:]), maker: maker)

        _ = await engine.pulseNow()
        _ = await engine.pulseNow()
        let snapshot = await engine.snapshot()

        #expect(snapshot.recent.count == 2)
        #expect(snapshot.lastDecision?.id == snapshot.recent.first?.id)
    }

    @Test func historyIsCappedAtTheConfiguredLimit() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [:]), maker: maker,
            config: LifeEngineConfig(historyLimit: 3))

        for _ in 0..<5 { _ = await engine.pulseNow() }

        #expect(await engine.snapshot().recent.count == 3)
    }

    @Test func decisionsReachTheEventStream() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [:]), maker: maker)
        let stream = await engine.events()

        _ = await engine.pulseNow()

        var seen: LifeDecision?
        for await event in stream {
            if case .decision(let decision) = event {
                seen = decision
                break
            }
        }
        #expect(seen != nil)
        #expect(seen?.outcome == .skipped)
    }

    @Test func aSkippedPulseStillSaysWhyInOneLine() async {
        let maker = ScriptedMaker()
        let engine = await makeEngine(
            slots: StaticSlots(slots: [.writing: slot(.writing)]),
            conditions: quiet(lastUserEpisodeAt: anchor.addingTimeInterval(-5)),
            maker: maker)

        let decision = await engine.pulseNow()

        #expect(decision.line.contains("skipped"))
        #expect(decision.line.contains("you spoke"))
    }
}
