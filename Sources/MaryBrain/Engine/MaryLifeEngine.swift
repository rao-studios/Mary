//
//  MaryLifeEngine.swift
//  MaryBrain
//
//  WHAT: The idle engine. Owns the pulse loop, the gates, the loaded adapter,
//        and the record of every decision it made.
//  IN:   LifeSlotProviding / LifeWorldProviding / LifeConditionsProviding
//  OUT:  LifeEngineSnapshot + LifeEngineEvent; episodes through the assembler
//  PIN:  ONE PULSE IS ONE DECISION, always recorded — including the ones that
//        refused. An engine that skips silently cannot be watched.
//  PIN:  `.observe` is the default mode. Acting unattended is opt-in.
//
import Foundation
import MaryFoundation
import os

public actor MaryLifeEngine {

    // MARK: - Seams

    private let slotSource: any LifeSlotProviding
    private let conditionSource: any LifeConditionsProviding
    private let worldSource: any LifeWorldProviding
    private let sessionMaker: any LifeAdapterSessionMaking
    private let behavior: BehavioralAssembler
    private var dispatcher: (any AbilityDispatching)?
    private let clock: @Sendable () -> Date
    private let appVersion: String

    // MARK: - State

    private var config: LifeEngineConfig
    private var mode: LifeMode
    private var phase: LifeEnginePhase = .off
    private var phaseDetail = ""
    private var slots: [AbilityID: LifeLoRASlot] = [:]
    private var fleetReachable = true
    private var session: (key: String, session: any LifeAdapterSessioning)?
    private var loadedAdapter: LifeAdapterRef?
    /// Newest first.
    private var history: [LifeDecision] = []
    private var cooldownUntil: Date?
    private var actsToday = 0
    private var actDay: Date?
    private var startedAt: Date?
    private var errorTail: [String] = []
    private var pulseInFlight = false
    /// Pulses since the loaded adapter was last used. See
    /// `LifeEngineConfig.idlePulsesBeforeUnload`.
    private var pulsesSinceAdapterUsed = 0
    private var loop: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<LifeEngineEvent>.Continuation] = [:]

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "life")

    public init(
        slots: any LifeSlotProviding,
        conditions: any LifeConditionsProviding,
        world: any LifeWorldProviding,
        sessionMaker: any LifeAdapterSessionMaking,
        behavior: BehavioralAssembler,
        dispatcher: (any AbilityDispatching)? = nil,
        config: LifeEngineConfig = LifeEngineConfig(),
        mode: LifeMode = .observe,
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.slotSource = slots
        self.conditionSource = conditions
        self.worldSource = world
        self.sessionMaker = sessionMaker
        self.behavior = behavior
        self.dispatcher = dispatcher
        self.config = config
        self.mode = mode
        self.appVersion = appVersion
        self.clock = clock
    }

    // MARK: - Monitoring

    public func snapshot() -> LifeEngineSnapshot {
        LifeEngineSnapshot(
            mode: mode,
            phase: phase,
            phaseDetail: phaseDetail,
            adapters: slots.values
                .map(LifeAdapterRef.init(slot:))
                .sorted { $0.abilityID.rawValue < $1.abilityID.rawValue },
            loadedAdapter: loadedAdapter,
            lastDecision: history.first,
            recent: history,
            nextEligibleAt: nextEligibleAt(),
            cooldownUntil: cooldownUntil,
            actsToday: actsToday,
            dailyActBudget: config.dailyActBudget,
            fleetReachable: fleetReachable,
            startedAt: startedAt,
            errorTail: errorTail)
    }

    /// Live activity. Every monitor reads this instead of polling.
    public func events() -> AsyncStream<LifeEngineEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LifeEngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit(_ event: LifeEngineEvent) {
        for continuation in observers.values { continuation.yield(event) }
    }

    // MARK: - Lifecycle

    public func setDispatcher(_ dispatcher: (any AbilityDispatching)?) {
        self.dispatcher = dispatcher
    }

    public func setConfig(_ config: LifeEngineConfig) {
        self.config = config
    }

    public func currentMode() -> LifeMode { mode }

    /// `startLoop: false` arms the mode without running the timer — how a
    /// probe asks for one pulse it can actually observe, instead of racing
    /// the loop's own.
    public func setMode(_ newMode: LifeMode, startLoop: Bool = true) {
        guard newMode != mode else { return }
        mode = newMode
        emit(.modeChanged(newMode))
        Self.log.info("life mode \(newMode.rawValue, privacy: .public)")
        switch newMode {
        case .off:
            stop()
        case .observe, .act:
            if startLoop { start() } else { setPhase(.paused, "not looping") }
        }
    }

    /// Idempotent. A second call while the loop runs is a no-op.
    public func start() {
        guard mode != .off, loop == nil else { return }
        startedAt = clock()
        setPhase(.idle, "")
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        unloadSession()
        setPhase(.off, "")
    }

    public func pause(reason: String) {
        loop?.cancel()
        loop = nil
        setPhase(.paused, reason)
    }

    public func resume() {
        guard mode != .off else { return }
        start()
    }

    public func isRunning() -> Bool { loop != nil }

    private func run() async {
        while !Task.isCancelled {
            _ = await pulse(dryRun: false)
            let period = config.period
            try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
        }
    }

    // MARK: - One pulse

    /// Run one pulse now. `dryRun` infers and records but never dispatches —
    /// what the Life sheet's button and the probe use to watch the engine
    /// think without letting it touch anything.
    @discardableResult
    public func pulseNow(dryRun: Bool = true) async -> LifeDecision {
        await pulse(dryRun: dryRun)
    }

    private func pulse(dryRun: Bool) async -> LifeDecision {
        let now = clock()
        guard mode != .off else {
            return record(skip(.modeOff, "the engine is off", at: now))
        }
        guard !pulseInFlight else {
            return record(skip(.pulseInFlight, "a pulse is already running", at: now))
        }
        pulseInFlight = true
        defer { pulseInFlight = false }

        await refreshAdapters()
        rollActDayIfNeeded(now: now)

        let conditions = await conditionSource.conditions()
        if let blocked = gate(conditions, dryRun: dryRun) {
            setPhase(.waiting, blocked.detail)
            return record(blocked)
        }

        guard let world = await worldSource.pulseWorld() else {
            setPhase(.waiting, "nothing is in front")
            return record(skip(.noLead, "nothing is in front", at: now))
        }

        let ready = slots.filter { $0.value.ready }
        guard !ready.isEmpty else {
            setPhase(.waiting, "no discipline has a ready adapter")
            return record(skip(
                .noReadyDiscipline, "no discipline has a ready adapter", at: now))
        }
        // THE LEAD PLACE DECIDES, and only the lead place. Reaching for any
        // ready discipline is how a Writing adapter ends up acting in Xcode.
        guard let abilityID = world.leadDisciplines.first(where: { ready[$0] != nil }),
              let slot = ready[abilityID]
        else {
            let detail = world.leadDisciplines.isEmpty
                ? "\(world.leadLabel) declares no discipline"
                : "no ready adapter for \(world.leadLabel)"
            setPhase(.waiting, detail)
            return record(skip(.leadHasNoDiscipline, detail, at: now))
        }

        let adapter = LifeAdapterRef(slot: slot)
        let resolved: any LifeAdapterSessioning
        do {
            resolved = try loadedSession(for: adapter)
        } catch let error as LifeEngineError {
            let detail = Self.describe(error)
            noteError(detail)
            setPhase(.waiting, detail)
            let reason: LifeSkipReason
            if case .modelMismatch = error { reason = .modelMismatch } else { reason = .adapterMissing }
            return record(skip(reason, detail, at: now, discipline: abilityID, adapter: adapter))
        } catch {
            let detail = error.localizedDescription
            noteError(detail)
            return record(skip(
                .adapterMissing, detail, at: now, discipline: abilityID, adapter: adapter))
        }

        setPhase(.inferring, "\(abilityID.rawValue) · gen \(adapter.generation)")
        pulsesSinceAdapterUsed = 0
        let started = DispatchTime.now()
        let completion: LifeCompletion
        do {
            completion = try await resolved.complete(
                input: world.input, schemaJSON: slot.schemaJSON)
        } catch {
            let detail = error.localizedDescription
            noteError(detail)
            setPhase(.idle, "")
            return record(LifeDecision(
                at: now, mode: mode, outcome: .dropped, detail: detail,
                discipline: abilityID, adapter: adapter, input: world.input))
        }
        let elapsedMs = Int(
            (DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000)

        var decision = LifeDecision(
            at: now,
            mode: mode,
            outcome: .silent,
            detail: "",
            discipline: abilityID,
            adapter: adapter,
            input: world.input,
            output: completion.output,
            actionCount: completion.output.actions.count,
            inferenceMs: elapsedMs,
            forcedFraction: completion.forcedFraction,
            promptTokens: completion.promptTokens)

        guard !completion.output.actions.isEmpty else {
            // RESTRAINT IS A RESULT. The adapter looked and chose nothing.
            setPhase(.idle, "")
            decision.detail = "nothing to do"
            return record(decision)
        }

        let mayAct = mode == .act && !dryRun
        setPhase(mayAct ? .acting : .inferring, abilityID.rawValue)
        let performed = await perform(
            completion.output,
            world: world,
            target: AbilityThreadTarget(abilityID: abilityID, paradigm: .discipline),
            dispatching: mayAct,
            at: now)
        decision.episodeID = performed.episodeID
        decision.outcome = performed.ranCount > 0 ? .acted : .proposed
        decision.actionCount = completion.output.actions.count
        decision.detail = performed.detail
        if performed.ranCount > 0 {
            actsToday += 1
            cooldownUntil = now.addingTimeInterval(config.actCooldown)
        }
        setPhase(cooldownUntil.map { $0 > now } == true ? .cooldown : .idle, "")
        return record(decision)
    }

    // MARK: - Gates

    /// The one place a pulse can be refused. Returns the refusal, or nil.
    private func gate(_ conditions: LifeConditions, dryRun: Bool) -> LifeDecision? {
        let now = conditions.now
        if conditions.isTurnInFlight {
            return skip(.turnInFlight, "a turn is open", at: now)
        }
        if conditions.isSkillRunning {
            return skip(.skillRunning, "a skill is running", at: now)
        }
        if conditions.isWorkspaceIndexing {
            return skip(.indexing, "the workspace is still indexing", at: now)
        }
        if let last = conditions.lastUserEpisodeAt {
            let ago = now.timeIntervalSince(last)
            if ago < config.quietAfterUser {
                return skip(
                    .userSpoke, "you spoke \(Self.ago(ago))", at: now)
            }
        }
        // A CONVERSATION PAUSE IS NOT AN IDLE MACHINE. Without this, Mary
        // acts into a window the person is actively typing in.
        if let idle = conditions.secondsSinceUserInput, idle < config.quietAfterInput {
            return skip(.userTyping, "you were typing \(Self.ago(idle))", at: now)
        }
        // A dry run is a person asking to see the engine think; cadence
        // limits exist to bound unattended acting, not observation.
        guard !dryRun else { return nil }
        if let until = cooldownUntil, until > now {
            return skip(
                .cooldown, "resting until \(Self.time(until))", at: now)
        }
        if mode == .act, actsToday >= config.dailyActBudget {
            return skip(
                .budgetSpent,
                "\(actsToday) of \(config.dailyActBudget) acts used today", at: now)
        }
        if !fleetReachable && slots.isEmpty {
            return skip(.fleetUnreachable, "Fleet isn't reachable", at: now)
        }
        return nil
    }

    private func rollActDayIfNeeded(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        if actDay != today {
            actDay = today
            actsToday = 0
        }
    }

    // MARK: - Acting

    private struct Performed {
        var episodeID: UUID?
        var ranCount: Int
        var detail: String
    }

    /// Open the episode, run or hold the predicted actions, seal it.
    private func perform(
        _ output: BehavioralTrainingOutput,
        world: LifeWorld,
        target: AbilityThreadTarget,
        dispatching: Bool,
        at now: Date
    ) async -> Performed {
        let episode = output.makeEpisode(
            id: UUID(),
            input: world.input.makeInput(),
            provenance: EpisodeProvenance(
                engine: "local", lane: Self.proactiveLane, appVersion: appVersion),
            abilityTargets: [target],
            openedAt: now)

        behavior.openEpisode(
            id: episode.id,
            query: episode.input.query,
            priorEpisodeID: episode.input.priorEpisodeID,
            provenance: episode.provenance,
            at: now)
        if let ambient = episode.input.ambient {
            behavior.stageCapture(ambient)
            behavior.claimStagedCapture(forEpisode: episode.id)
        }
        behavior.noteAbilityTargets(episode.abilityTargets, forEpisode: episode.id)

        var ran = 0
        var held = 0
        if dispatching {
            let dispatcher = self.dispatcher
            var runnable: [BehavioralAction] = []
            for record in episode.output.actions {
                let name = Self.dispatchName(record.action)
                if dispatcher?.isUnattendedSafe(name) ?? false {
                    runnable.append(record.action)
                } else {
                    // AN EFFECTFUL ACT WITH NOBODY WATCHING IS NOT A
                    // PREDICTION THE ENGINE GETS TO MAKE. Held, recorded,
                    // and visible — not run.
                    hold(record, episodeID: episode.id, at: now)
                    held += 1
                }
            }
            if !runnable.isEmpty {
                let records = await dispatcher?.perform(
                    sequence: runnable, episodeID: episode.id) ?? []
                ran = records.filter { $0.disposition.didRun }.count
            }
        } else {
            for record in episode.output.actions {
                hold(record, episodeID: episode.id, at: now)
                held += 1
            }
        }
        behavior.seal(episode.id, reason: .completed, at: clock())

        let detail: String
        if ran > 0 && held > 0 {
            detail = "\(ran) run, \(held) held"
        } else if ran > 0 {
            detail = "\(ran) run"
        } else if mode == .observe {
            detail = "\(held) proposed — observe mode"
        } else {
            detail = "\(held) held — needs you"
        }
        return Performed(episodeID: episode.id, ranCount: ran, detail: detail)
    }

    /// Record a predicted action that was NOT run.
    private func hold(
        _ record: BehavioralActionRecord, episodeID: UUID, at now: Date
    ) {
        var held = record
        held.disposition = .deferred
        held.initiator = .maryAct
        held.startedAt = now
        held.finishedAt = now
        if held.summary.isEmpty {
            held.summary = "Proposed while idle; not run."
        }
        behavior.append(held, toEpisode: episodeID)
    }

    public static func dispatchName(_ action: BehavioralAction) -> String {
        action.skill.invocationName.isEmpty
            ? action.intention : action.skill.invocationName
    }

    // MARK: - Adapters

    private func refreshAdapters() async {
        let result = await slotSource.adapters()
        let changed = result.slots != slots
        slots = result.slots
        fleetReachable = result.reachable
        if changed {
            let refs = slots.values
                .map(LifeAdapterRef.init(slot:))
                .sorted { $0.abilityID.rawValue < $1.abilityID.rawValue }
            emit(.adaptersChanged(refs))
            // A RETRAIN KEEPS THE PATH AND CHANGES THE WEIGHTS. Holding the
            // old session would act through last generation's adapter until
            // the app relaunched.
            if let loaded = loadedAdapter,
               let live = slots[loaded.abilityID],
               live.cid != loaded.cid
            {
                unloadSession()
            }
        }
    }

    private func loadedSession(
        for adapter: LifeAdapterRef
    ) throws -> any LifeAdapterSessioning {
        if let session, session.key == adapter.sessionKey {
            return session.session
        }
        unloadSession()
        let made = try sessionMaker.makeSession(adapter: adapter)
        session = (key: adapter.sessionKey, session: made)
        loadedAdapter = adapter
        emit(.adapterLoaded(adapter))
        return made
    }

    private func unloadSession() {
        guard let previous = loadedAdapter else {
            session = nil
            return
        }
        session = nil
        loadedAdapter = nil
        emit(.adapterUnloaded(cid: previous.cid))
    }

    // MARK: - Bookkeeping

    private func setPhase(_ next: LifeEnginePhase, _ detail: String) {
        guard next != phase || detail != phaseDetail else { return }
        phase = next
        phaseDetail = detail
        emit(.phaseChanged(next, detail: detail))
    }

    private func skip(
        _ reason: LifeSkipReason,
        _ detail: String,
        at now: Date,
        discipline: AbilityID? = nil,
        adapter: LifeAdapterRef? = nil
    ) -> LifeDecision {
        LifeDecision(
            at: now, mode: mode, outcome: .skipped, skip: reason, detail: detail,
            discipline: discipline, adapter: adapter)
    }

    /// A pulse that never reached the adapter. After a few of these the
    /// weights are let go — the next pulse that needs them loads them again.
    private func noteAdapterUnused() {
        guard loadedAdapter != nil else { return }
        pulsesSinceAdapterUsed += 1
        if pulsesSinceAdapterUsed >= config.idlePulsesBeforeUnload {
            pulsesSinceAdapterUsed = 0
            unloadSession()
        }
    }

    @discardableResult
    private func record(_ decision: LifeDecision) -> LifeDecision {
        if decision.outcome == .skipped { noteAdapterUnused() }
        history.insert(decision, at: 0)
        if history.count > config.historyLimit {
            history.removeLast(history.count - config.historyLimit)
        }
        emit(.decision(decision))
        let line = "life \(decision.shortID) \(decision.line)"
        Self.log.info("\(line, privacy: .public)")
        return decision
    }

    private func noteError(_ detail: String) {
        errorTail.insert(detail, at: 0)
        if errorTail.count > 6 { errorTail.removeLast(errorTail.count - 6) }
        emit(.failed(detail))
    }

    private func nextEligibleAt() -> Date? {
        guard mode != .off, loop != nil else { return nil }
        let base = clock().addingTimeInterval(config.period)
        guard let until = cooldownUntil, until > base else { return base }
        return until
    }

    // MARK: - The turn path

    /// Disciplines whose ready adapter may answer a live user turn in place
    /// of tool-calling. Opt-in per discipline: a 24-example adapter taking
    /// over every turn the moment it goes ready is a cliff, not a feature.
    private var actsOnTurns: Set<AbilityID> = []

    public func setActsOnTurns(_ ids: Set<AbilityID>) {
        actsOnTurns = ids
    }

    public func turnsOptedIn() -> Set<AbilityID> { actsOnTurns }

    /// The invocations a ready, opted-in adapter would answer this turn with,
    /// or nil to let the model speak. Recorded like any other decision, so
    /// the monitor shows turns the adapter took over.
    public func turnInvocations(
        targets: [AbilityThreadTarget],
        input: BehavioralTrainingInput,
        episodeID: UUID
    ) async -> [ModelSkillInvocation]? {
        guard mode == .act, !actsOnTurns.isEmpty else { return nil }
        await refreshAdapters()
        let disciplines = targets.filter { $0.paradigm == .discipline }
        guard let target = disciplines.first(where: {
                  actsOnTurns.contains($0.abilityID) && slots[$0.abilityID]?.ready == true
              }),
              let slot = slots[target.abilityID]
        else { return nil }

        let adapter = LifeAdapterRef(slot: slot)
        let now = clock()
        let started = DispatchTime.now()
        do {
            let session = try loadedSession(for: adapter)
            let completion = try await session.complete(
                input: input, schemaJSON: slot.schemaJSON)
            let elapsedMs = Int(
                (DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds)
                    / 1_000_000)
            let invocations = completion.output.actions.enumerated().map { index, action in
                ModelSkillInvocation(
                    id: "life-\(episodeID.uuidString.lowercased())-\(index)",
                    name: action.invocationName.isEmpty
                        ? action.intention : action.invocationName,
                    argumentsJSON: action.argumentsJSON.isEmpty
                        ? "{}" : action.argumentsJSON)
            }
            record(LifeDecision(
                at: now,
                mode: mode,
                outcome: invocations.isEmpty ? .silent : .acted,
                detail: "answered a turn",
                discipline: target.abilityID,
                adapter: adapter,
                input: input,
                output: completion.output,
                actionCount: invocations.count,
                inferenceMs: elapsedMs,
                forcedFraction: completion.forcedFraction,
                promptTokens: completion.promptTokens,
                episodeID: episodeID))
            return invocations
        } catch {
            // THE TURN IS NOT THE PLACE TO FAIL. Fall through to the model.
            let detail = (error as? LifeEngineError).map(Self.describe)
                ?? error.localizedDescription
            noteError(detail)
            record(LifeDecision(
                at: now, mode: mode, outcome: .dropped, detail: detail,
                discipline: target.abilityID, adapter: adapter, input: input,
                episodeID: episodeID))
            return nil
        }
    }

    // MARK: - Training progress passthrough

    /// The trainer's ticks ride the engine's stream so one subscription
    /// carries everything Life does.
    public func noteTrainingChanged() async {
        await refreshAdapters()
    }

    // MARK: - Strings

    /// The lane every Life-produced episode is stamped with.
    public static let proactiveLane = EpisodeProvenance.proactiveLane

    static func describe(_ error: LifeEngineError) -> String {
        switch error {
        case .invalidSchema:
            return "the adapter's schema did not decode"
        case .modelMismatch(let expected, let got):
            return "adapter was trained on \(got), engine runs \(expected)"
        case .fleetUnreachable(let reason):
            return "Fleet could not answer: \(reason)"
        case .noAdapter:
            return "no adapter"
        }
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s ago" }
        return "\(value / 60)m ago"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
