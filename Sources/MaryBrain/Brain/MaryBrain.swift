//
//  MaryBrain.swift
//  MaryBrain
//
//  WHAT: Conversation history + Skill loop. VoicePipeline and SendText both
//        drive this actor (serializes overlap). InferenceEngine is transport.
//  OUT:  BrainEvent → SpeechRouter / ChatService.MirrorVoice
//        Seer mode: Seer speaks; engine runs skills silently.
//        Local mode: single-engine loop.
//
//  This file: actor, stored state, init, LanguageResponder.
//    AbilityDispatching.swift        dispatcher seam + SeerPass
//    BrainConcurrency.swift          ProactiveMulticast, LaneEmitter, TurnBox, AsyncGate
//    MaryBrain+Configuration.swift  set* wiring
//    MaryBrain+History.swift          epoch-guarded history
//    MaryBrain+TurnLoop.swift         runTurn / runTurnBody
//    MaryBrain+TurnLog.swift          turnLog circuit (Xcode / pair-coding)
//    MaryBrain+Route.swift            revision spine
//    MaryBrain+SeerTurn.swift         seerTurn
//    MaryBrain+Lanes.swift           Seer / realtime / orchestrator lanes
//    MaryBrain+Routines.swift         detached routines + follow-ups
//    MaryBrain+LocalTurn.swift        single-engine loop
//    MaryBrain+Deposit.swift           archive
//    MaryBrain+Vocabulary.swift       spoken sentences
//    MaryBrain+GroundedText.swift     grounded-text statics
//    MaryBrain+UtteranceGates.swift   yes/no, correction, accepted-offer
//    MaryBrain+Types.swift            RevisionVeto, LocatedArtifact, WorldVeto
//  Split members: "internal for file split — treat as private".
//

import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

public actor MaryBrain: LanguageResponder {

    // internal for file split — treat as private
    var engine: any InferenceEngine

    /// Provenance stamp so on-device and hosted turns stay distinct datasets.
    func behavioralProvenance(lane: String = "dual") -> EpisodeProvenance {
        EpisodeProvenance(
            engine: engine.choice.rawValue,
            lane: lane,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }
    // internal for file split — treat as private
    var dispatcher: (any AbilityDispatching)?
    /// Roster-backed reference resolution. Nil in a headless probe.
    // internal for file split — treat as private
    var referentResolver: (@Sendable (ReferenceAct) -> ReferenceDecision)?
    /// One-word correction → re-aimed rival. Runtime-installed; nil = nowhere to land.
    // internal for file split — treat as private
    var referenceCorrector:
        (@Sendable (ResolvedReferent) -> ReferenceResolver.Rival?)?

    // internal for file split — treat as private
    var systemPromptProvider: @Sendable () -> String
    /// Seer chat lane. Nil (or not ready) = local single-engine turns.
    // internal for file split — treat as private
    var seerChat: (any SeerChatProviding)?
    /// Optional realtime WS route (Settings). Nil = classic only.
    // internal for file split — treat as private
    var seerRealtime: (any SeerRealtimeProviding)?
    /// Seer persona/instructions. Separate from the engine system prompt (Skill doctrine).
    /// IN:  SeerPass. Nil world = resolve live. Detached follow-ups must pass spawn world.
    /// PIN: `runTurn` defer clears utterance override; ambient focus would lie.
    // internal for file split — treat as private
    var seerInstructionsProvider: @Sendable (SeerPass) -> String = { pass in
        MaryPrompts.seerInstructions(
            groundedResults: pass.groundedResults,
            readPassages: pass.readPassages,
            readReport: pass.readReport,
            conversational: pass.conversational,
            // Running-actions is a catalog section; every provider must pass it through.
            runningActions: pass.runningActionLabels,
            lookUnderway: pass.lookUnderway,
            inspiredSight: pass.inspiredSight,
            perceiving: pass.perceiving)
    }
    /// Fire-and-forget Skill-result archive into Totem.
    // internal for file split — treat as private
    var depositor: (any ContextDepositing)?
    /// Archive subject, read synchronously at deposit (focus may have moved by then).
    /// PIN: Same focus decision as the prompt providers.
    // internal for file split — treat as private
    var depositSubjectProvider: @Sendable () -> DepositSubject = { .unfocused }
    /// Cross-cutting stores (`BrainWiring`). Default-fresh = isolated; runtime injects process-wide.
    // internal for file split — treat as private
    var wiring: BrainWiring
    /// Last READ delivery (debugger row). Seeded from `wiring`; tests inject via setter.
    // internal for file split — treat as private
    var readLedger: ReadDeliveryLedger
    /// Short-term awareness, hosted. Turn loop writes utterance + spoken-about; watchers write facts.
    /// Seeded from `wiring`.
    // internal for file split — treat as private
    var world: AmbientWorld
    /// Refresh volatile frontmost context (AX selection) before classify/prompt.
    // internal for file split — treat as private
    var turnContextPreparer: (@Sendable () async -> Void)?
    /// Lane join/detach log — catches fast actions detaching from queueing, not work.
    // internal for file split — treat as private
    static let laneLog = Logger(subsystem: "nyc.rao.mary", category: "lanes")
    /// Full-turn circuit — Xcode awareness through pair-coding dispatch, including misses.
    // public because it is accessible via MaryRuntime.
    public static let turnLog = Logger(subsystem: "nyc.rao.mary", category: "turns")

    // internal for file split — treat as private
    var history: [BrainTurn] = []
    /// Last named/owned application. Conversational salience, not durable focus or a grant.
    /// PIN: Mary's surface can steal NSWorkspace frontmost before a typed follow-up.
    // internal for file split — treat as private
    var recentApplicationReferent: (id: String, resolvedAt: Date)?
    // internal for file split — treat as private
    static let applicationReferentLifetime: TimeInterval = 5 * 60
    /// Passage the conversation is about. Armed on a selection brief; spent by next-turn acceptance.
    /// PIN: Sibling of `recentApplicationReferent` — outlives the turn-scoped selection channel.
    struct DiscussedPassageReferent: Sendable, Equatable {
        /// Exact handoff text — never the prompt-clipped fact.
        var text: String
        /// WHERE the passage was discussed, spelled as `OfferedProseReferent` spells
        /// it — one place, not the `(attention, applicationID)` pair it holds.
        var place: AmbientPlace
        var armedAt: Date
        /// Arming turn id. An intervening exchange kills acceptance.
        var armedByExchange: UUID
    }
    // internal for file split — treat as private
    var discussedPassageReferent: DiscussedPassageReferent?

    /// Prose Mary offered last turn — acceptance writes these exact bytes. See `OfferedProse`.
    /// PIN: Sibling of `discussedPassageReferent`, not a widening; two acceptance roads cannot cross.
    struct OfferedProseReferent: Sendable, Equatable {
        /// Mary's exact bytes (emphasis and outer quotes stripped).
        var text: String
        /// Place the offer was about. Nil when no world led.
        var place: AmbientPlace?
        var armedAt: Date
        /// User turn that prompted the offer (adjacency; same shape as DiscussedPassageReferent).
        var armedByExchange: UUID
    }
    // internal for file split — treat as private
    var offeredProseReferent: OfferedProseReferent?
    /// Previous user-turn id, captured at entry. `bareAcceptance` adjacency; no history scan.
    // internal for file split — treat as private
    var lastUserTurnID: UUID?
    /// In-flight exchange: set when the user turn lands, cleared at exit.
    /// PIN: A new turn finding this non-nil supersedes — drop history + UI bubbles together.
    // internal for file split — treat as private
    var openExchange: (userTurnID: UUID, epoch: UInt64)?
    /// The idle engine, installed by Runtime. Nil = no Life in this process.
    // internal for file split — treat as private
    var lifeEngine: MaryLifeEngine?
    // internal for file split — treat as private
    let turnBox = TurnBox()
    /// Brain-initiated events outside turns — routine progress + follow-ups.
    // internal for file split — treat as private
    let proactive = ProactiveMulticast()

    // internal for file split — treat as private
    var activeRoutines: [UUID: ActiveRoutine] = [:]
    /// Watchdog-expired routines, kept so a late lane result can still deliver.
    /// PIN: `finishRoutine` used to `guard` only `activeRoutines` and drop late work.
    // internal for file split — treat as private
    var expiredRoutines: [UUID: LateRoutine] = [:]
    /// Unstructured settle hop per routine (await lane → `finishRoutine`). Self-removing.
    // internal for file split — treat as private
    var settleTasks: [UUID: Task<Void, Never>] = [:]
    /// Last cleared routine — tests observe both clocks cancelled. Production never reads.
    // internal for file split — treat as private
    var lastClearedRoutine: ActiveRoutine?
    /// Join-or-detach grace after Seer's reply. Slow lanes detach and follow up.
    /// PIN: Must equal `KokoroStreamSpeaker.takeoverHoldNanoseconds` (`TakeoverTests`).
    static let laneJoinGraceNanoseconds: UInt64 = 250_000_000
    /// Live spoken-turn grace. Production uses the static; tests shrink it.
    // internal for file split — treat as private
    var laneJoinGraceLiveNanoseconds: UInt64 = MaryBrain.laneJoinGraceNanoseconds
    /// Action-turn join grace (no voice racing). Longer so chips stay in-turn.
    // internal for file split — treat as private
    var actionJoinGraceNanoseconds: UInt64 = 5_000_000_000
    /// Fetch-first voice budget. Past it the turn proceeds; the read is a bonus.
    // internal for file split — treat as private
    static let preReadBudgetNanoseconds: UInt64 = 2_500_000_000
    /// Pre-lane look ceiling. Past it the turn proceeds lookless; description follows up.
    static let preLookBudgetNanoseconds: UInt64 = 8_000_000_000
    /// Pre-lane AWARENESS ceiling. Shorter than the look's, because this is
    /// disk and regex rather than a screenshot and a vision round — and
    /// because it runs on ordinary turns, where a slow answer is worse than a
    /// less-informed one.
    static let preAwarenessBudgetNanoseconds: UInt64 = 2_500_000_000
    // internal for file split — treat as private
    static let turnContextRefreshBudgetNanoseconds: UInt64 = 1_000_000_000

    func setReadLedgerForTesting(_ ledger: ReadDeliveryLedger) {
        readLedger = ledger
    }

    func setActionJoinGraceForTesting(_ nanoseconds: UInt64) {
        actionJoinGraceNanoseconds = nanoseconds
    }

    func setLaneJoinGraceForTesting(_ nanoseconds: UInt64) {
        laneJoinGraceLiveNanoseconds = nanoseconds
    }

    /// Run `work` or give up after `budget`. Abandoned work is always a READ.
    // internal for file split — treat as private
    func withNanosecondBudget<T: Sendable>(
        _ budget: UInt64, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Test seams: Seer-wire view and history roles (alternation invariant).
    func spokenMessagesForTesting() -> [SeerChatMessage] { spokenMessages() }
    func historyRolesForTesting() -> [BrainTurn.Role] { history.map(\.role) }
    /// Hung-lane wall-clock cap. Expiry speaks (`expireRoutine`).
    /// PIN: 7 min = Subprocess 300 s + StreamingHTTP 120 s; do not cut deeper than real builds.
    static let routineWatchdogDefault: UInt64 = 420_000_000_000   // 7 min
    // internal for file split — treat as private
    var routineWatchdogNanoseconds = MaryBrain.routineWatchdogDefault

    /// Progress marks while a slow lane is still working. Two marks, never a period.
    /// PIN: 45 s (AppleScript 30 + ~15) then 210 s (watchdog/2). Ceiling of three spoken artefacts.
    static let routineProgressFirstMark: UInt64 = 45_000_000_000    // 30 + ~15
    static let routineProgressSecondMark: UInt64 = 210_000_000_000  // 420 / 2
    static let routineProgressMarksDefault: [UInt64] = [
        routineProgressFirstMark, routineProgressSecondMark,
    ]
    /// Live progress marks. Instance-scoped so tests need not wait 45 real seconds.
    // internal for file split — treat as private
    var routineProgressMarks = MaryBrain.routineProgressMarksDefault

    func setRoutineProgressMarksForTesting(_ marks: [UInt64]) {
        routineProgressMarks = marks
    }
    // internal for file split — treat as private
    var followUpChain: ChainEntry?

    /// Follow-up wall-clock ladder. Inner bound fires first; outer only catches.
    /// PIN: A wedged `seerChat.stream` must not silence the chain globally.

    /// Seer compose budget for one follow-up. Past this, deterministic fallback recites.
    static let followUpSpeechBudget: TimeInterval = 20
    /// One chain entry's whole body. Strictly above speech budget.
    static let followUpBodyBudget: TimeInterval = 25
    /// Wait for predecessor. Constant, not a sum — the chain drains rather than accumulates.
    static let followUpChainWaitBudget: TimeInterval = 30
    /// `finishRoutine` wait after speech. Strictly above wait + body.
    static let followUpHandoffBudget: TimeInterval = 60

    /// Live ladder, instance-scoped so tests can reach the wedge in milliseconds.
    // internal for file split — treat as private
    var speechBudget = MaryBrain.followUpSpeechBudget
    // internal for file split — treat as private
    var bodyBudget = MaryBrain.followUpBodyBudget
    // internal for file split — treat as private
    var chainWaitBudget = MaryBrain.followUpChainWaitBudget
    // internal for file split — treat as private
    var handoffBudget = MaryBrain.followUpHandoffBudget

    /// Test seam: chain only, no routine. A wedged entry must not take its successors.
    func enqueueFollowUpForTesting(_ body: @escaping @Sendable () async -> Void) async {
        await enqueueFollowUp(origin: nil) { _ in await body() }
    }

    /// Test seam: whole ladder, scaled. Ratios stay the production contract.
    func setFollowUpBudgetScaleForTesting(_ scale: Double) {
        speechBudget = Self.followUpSpeechBudget * scale
        bodyBudget = Self.followUpBodyBudget * scale
        chainWaitBudget = Self.followUpChainWaitBudget * scale
        handoffBudget = Self.followUpHandoffBudget * scale
    }
    /// Serializes engine generation across orchestrator lanes. Skill exec interleaves freely.
    // internal for file split — treat as private
    let engineGate = AsyncGate()

    func setRoutineWatchdogForTesting(_ nanoseconds: UInt64) {
        routineWatchdogNanoseconds = nanoseconds
    }

    /// Did terminal cancel both clocks of the last cleared routine? Nil-tolerant.
    func lastClearedRoutineClocksCancelledForTesting() -> Bool {
        guard let routine = lastClearedRoutine else { return false }
        return (routine.watchdogTask?.isCancelled ?? true)
            && (routine.progressTask?.isCancelled ?? true)
    }

    /// Await every active progress clock rundown — proof no further mark can speak.
    func awaitProgressClockRundownForTesting() async {
        for routine in activeRoutines.values {
            await routine.progressTask?.value
        }
    }

    /// Await lanes, settles, and follow-up chain in waves. Wave cap returns false instead of hanging.
    /// PIN: Call-site rule lives in BrainTestSupport.swift.
    @discardableResult
    func awaitQuiescenceForTesting(maxWaves: Int = 16) async -> Bool {
        for _ in 0..<maxWaves {
            let lanes = activeRoutines.values.map(\.task)
            let settles = Array(settleTasks.values)
            // Chain is never nilled: drained ≠ pending. Identity check stops a chase loop.
            let chainTask = followUpChain?.task
            for lane in lanes { _ = await lane.value }
            for settle in settles { await settle.value }
            if let chainTask { await chainTask.value }
            if activeRoutines.isEmpty, settleTasks.isEmpty,
               followUpChain?.task == chainTask {
                return true
            }
        }
        return false
    }

    /// Cancel then drain — timeout-path tests. Relies on ArrivalSignal cancellation.
    func cancelRoutinesForTesting() async {
        for (id, routine) in activeRoutines {
            routine.task.cancel()
            clearActiveRoutine(id: id)
        }
        for task in settleTasks.values { task.cancel() }
        await awaitQuiescenceForTesting()
    }

    /// Coding/writing focus. Per-turn utterance override wins. Seeded from `wiring`.
    // internal for file split — treat as private
    var focusTracker: WorkspaceFocusTracker

    /// Rolling spoken-message window. Skill chatter rides its exchange. Settable from Settings.
    // internal for file split — treat as private
    var historyMessageLimit = 12
    /// Subshell round cap; closed by a forced wrap-up.
    // internal for file split — treat as private
    let maxSkillRounds = 10

    public init(
        engine: any InferenceEngine,
        dispatcher: (any AbilityDispatching)? = nil,
        systemPrompt: String = MaryPrompts.system(plugins: [], projects: [:]),
        wiring: BrainWiring = BrainWiring()
    ) {
        self.engine = engine
        self.dispatcher = dispatcher
        self.systemPromptProvider = { systemPrompt }
        self.wiring = wiring
        self.readLedger = wiring.readLedger
        self.world = wiring.world
        self.focusTracker = wiring.focusTracker
    }

    // MARK: - Configuration

    /// Isolated focus tracker so turn-override tests never touch process-wide.
    func setFocusTrackerForTesting(_ tracker: WorkspaceFocusTracker) {
        self.focusTracker = tracker
    }
}
