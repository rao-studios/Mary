//
//  MaryRuntime+Life.swift
//  MaryRuntime
//
//  WHAT: Wiring for the Life engine and its trainer, and the Life sheet's
//        calibration read.
//  IN:   sealed episodes; app settings
//  OUT:  MaryLifeEngine (the loop, the gates, the acting) + LifeTrainer
//  PIN:  No loop, no gates and no adapters live here any more. This file
//        builds the engine, feeds the trainer, and answers the sheet.
//
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import os

extension MaryRuntime {

    static let lastUserEpisodeAtBox = OSAllocatedUnfairLock<Date?>(initialState: nil)
    static let totemNodeIDBox = OSAllocatedUnfairLock<String>(initialState: "")
    private static let behaviorEpisodesBox =
        OSAllocatedUnfairLock<[BehavioralEpisode]>(initialState: [])
    /// When the episode cache was last filled from Totem. A full export is
    /// up to fifty pages; doing it twice per sealed turn made the cost of
    /// remembering a turn grow with the number of turns already remembered.
    private static let behaviorExportedAtBox =
        OSAllocatedUnfairLock<Date?>(initialState: nil)
    static let behaviorExportMinimumInterval: TimeInterval = 30
    private static let lifeLog = Logger(subsystem: "nyc.rao.mary", category: "life")
    /// Mode the app configured, read when the engine is built at install.
    /// `.off` until settings say otherwise — an engine that acts before the
    /// user has seen it exists is not a default.
    static let lifeModeBox = OSAllocatedUnfairLock<LifeMode>(initialState: .off)
    /// Builds the pulse world from the live focus stack. Installed with the
    /// rest of the brain's providers, because that is where `deps` exists.
    /// Nil before install: the engine then reports "nothing is in front"
    /// rather than inventing a world.
    static let lifeWorldBox =
        OSAllocatedUnfairLock<(@Sendable (Date) -> LifeWorld?)?>(initialState: nil)

    /// The quiet world, projected exactly as a user turn's input is.
    static func idleWorld(deps: FocusResolutionContext, at now: Date) -> LifeWorld? {
        let resolved = resolveFocus(deps: deps)
        guard let lead = resolved.leadPlace else { return nil }
        let rendering = heldContext(resolved, budget: AmbientRanker.abilityBudget)
        let capture = behavioralCapture(rendering: rendering, lead: lead, at: now)
        let input = BehavioralInput(
            query: LifeWorldProvider.idleQuery, ambient: capture)
        return LifeWorld(
            input: BehavioralTrainingInput(input: input),
            leadDisciplines: LifeWorldProvider.disciplines(
                lead: lead, profiles: applicationProfiles()),
            leadLabel: lead.displayName)
    }

    /// Adapters, dialed and cached. The engine reads this; so does the sheet.
    package static let lifeSlots = LifeSlotProvider()

    /// The idle engine. One per process, built once.
    package static let lifeEngine = MaryLifeEngine(
        slots: lifeSlots,
        conditions: LifeConditionsProvider(),
        world: LifeWorldProvider(),
        sessionMaker: FleetRemoteAdapterSessionMaker(
            modelID: LifeBaseModel.defaultModelID,
            totemID: { totemNodeIDBox.withLock { $0 } },
            fleet: { makeFleetClient() }),
        behavior: brainWiring.behavior,
        mode: .off)

    /// Threshold training. Refreshes adapters when a run publishes.
    package static let lifeTrainer = LifeTrainer { _ in
        await lifeEngine.noteTrainingChanged()
    }

    // MARK: - Wiring

    /// Called once brain configuration is installed and the dispatcher exists.
    static func startLifeEngine(dispatcher: (any AbilityDispatching)?, mode: LifeMode) async {
        await lifeEngine.setDispatcher(dispatcher)
        await brain.setLifeEngine(lifeEngine)
        await refreshBehaviorEpisodesFromTotem()
        await lifeEngine.setMode(mode)
    }

    package static func setLifeMode(_ mode: LifeMode) async {
        lifeModeBox.withLock { $0 = mode }
        await lifeEngine.setMode(mode)
    }

    /// Disciplines whose adapter may answer a live turn. Opt-in, per
    /// ability: a twenty-four example adapter taking over every turn the
    /// moment it goes ready is a cliff, not a feature.
    package static func setLifeTurnDisciplines(_ ids: Set<String>) async {
        await lifeEngine.setActsOnTurns(Set(ids.map(AbilityID.init)))
    }

    /// Arm a mode without starting the loop — the probe's entry point.
    package static func armLifeMode(_ mode: LifeMode) async {
        await lifeEngine.setMode(mode, startLoop: false)
    }

    package static func lifeTurnDisciplines() async -> Set<String> {
        Set(await lifeEngine.turnsOptedIn().map(\.rawValue))
    }

    package static func lifeEngineSnapshot() async -> LifeEngineSnapshot {
        await lifeEngine.snapshot()
    }

    package static func lifeEngineEvents() async -> AsyncStream<LifeEngineEvent> {
        await lifeEngine.events()
    }

    /// One pulse on demand. Dry by default: infer, record, dispatch nothing.
    @discardableResult
    package static func lifePulseNow(dryRun: Bool = true) async -> LifeDecision {
        await lifeEngine.pulseNow(dryRun: dryRun)
    }

    package static func refreshReadyLoRAs() async {
        await lifeSlots.refresh()
        await lifeEngine.noteTrainingChanged()
    }

    /// Cheap overlay flag for the Totems pane.
    package static func lifeIsTraining() async -> Bool {
        await lifeTrainer.isTraining()
    }

    // MARK: - Episodes

    /// Called after a sealed episode is handed to Totem. User turns stamp the
    /// quiet clock; every completed discipline episode may trip a train.
    static func noteSealedEpisode(_ episode: BehavioralEpisode) {
        let id = BehavioralAssembler.shortID(episode.id)
        BehavioralAssembler.behavioralLog.info("life noted \(id, privacy: .public)")
        // MARY'S OWN IDLE EPISODES ARE NOT THE USER SPEAKING, and they are not
        // training material either. Counting them would let the engine reset
        // its own quiet clock and learn from its own output.
        guard !episode.provenance.isProactive else { return }
        lastUserEpisodeAtBox.withLock { $0 = Date() }
        Task { await considerTrain(episode) }
    }

    static func considerTrain(_ episode: BehavioralEpisode) async {
        let id = BehavioralAssembler.shortID(episode.id)
        guard let owner = await seerSession.userID else {
            BehavioralAssembler.behavioralLog.info(
                "train skipped \(id, privacy: .public) — unsigned in")
            return
        }
        let totemID = totemNodeIDBox.withLock { $0 }
        guard !totemID.isEmpty else {
            BehavioralAssembler.behavioralLog.info(
                "train skipped \(id, privacy: .public) — no totem id")
            return
        }
        await lifeSlots.refresh()
        // The deposit path already refreshed this cache moments ago.
        await refreshBehaviorEpisodesFromTotem(ifOlderThan: behaviorExportMinimumInterval)
        await lifeTrainer.consider(
            episode: episode,
            episodes: behaviorEpisodesBox.withLock { $0 },
            slots: await lifeSlots.lastKnown().slots,
            ownerID: owner,
            totemID: totemID)
    }

    /// Pull Ability-lane behavior documents into the calibration cache.
    /// A failed export leaves the previous cache in place.
    package static func refreshBehaviorEpisodesFromTotem() async {
        guard let episodes = await totemContext.exportBehaviorEpisodes() else { return }
        behaviorEpisodesBox.withLock { $0 = episodes }
        behaviorExportedAtBox.withLock { $0 = Date() }
    }

    /// Refresh only if the cache is stale. Two callers fire on every sealed
    /// episode — the deposit, then the train check — and both want the same
    /// list a second apart.
    static func refreshBehaviorEpisodesFromTotem(ifOlderThan interval: TimeInterval) async {
        let last = behaviorExportedAtBox.withLock { $0 }
        if let last, Date().timeIntervalSince(last) < interval { return }
        await refreshBehaviorEpisodesFromTotem()
    }

    package static func behaviorEpisode(id: UUID) async -> BehavioralEpisode? {
        await totemContext.episode(id: id)
    }

    static func clearBehaviorEpisodeCache() {
        behaviorEpisodesBox.withLock { $0 = [] }
        behaviorExportedAtBox.withLock { $0 = nil }
    }

    // MARK: - Calibration

    /// Join installed disciplines, Totem episode counts, and cached Fleet
    /// slots. Does not dial Fleet or Totem — call `refreshReadyLoRAs` and
    /// `refreshBehaviorEpisodesFromTotem` when the sheet opens.
    package static func lifeCalibration() async -> LifeCalibrationSnapshot {
        let disciplines = LifeCalibration.disciplines(
            in: AbilityLibrary.shared.snapshot().records.map(\.package))
        let known = await lifeSlots.lastKnown()
        return LifeCalibration.snapshot(
            disciplines: disciplines,
            episodes: behaviorEpisodesBox.withLock { $0 },
            slots: known.slots,
            ticks: await lifeTrainer.ticks(),
            tails: await lifeTrainer.logTails(),
            fleetReachable: known.reachable)
    }
}
