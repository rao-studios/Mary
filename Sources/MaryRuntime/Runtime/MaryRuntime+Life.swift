//
//  MaryRuntime+Life.swift
//  MaryRuntime
//
//  Threshold training and the idle Life loop: pulse → gated complete →
//  re-encode → autonomous dispatcher → seal.
//

import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import os

extension MaryRuntime {

    static let lastUserEpisodeAtBox = OSAllocatedUnfairLock<Date?>(initialState: nil)
    static let lifeSlotsBox =
        OSAllocatedUnfairLock<[AbilityID: LifeLoRASlot]>(initialState: [:])
    static let totemNodeIDBox = OSAllocatedUnfairLock<String>(initialState: "")
    private static let lifeEnabledBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let lifeLoopBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private static let trainingDisciplinesBox =
        OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static let lifeTrainProgressBox =
        OSAllocatedUnfairLock<[AbilityID: LifeTrainTick]>(initialState: [:])
    private static let lifeTrainTailBox =
        OSAllocatedUnfairLock<[AbilityID: [String]]>(initialState: [:])
    private static let fleetReachableBox = OSAllocatedUnfairLock<Bool>(initialState: true)
    private static let behaviorEpisodesBox =
        OSAllocatedUnfairLock<[BehavioralEpisode]>(initialState: [])
    private static let lifeLog = Logger(subsystem: "nyc.rao.mary", category: "life")

    /// Called after a sealed episode is handed to Totem. User turns stamp the
    /// quiet clock; every completed discipline episode may trip a train.
    static func noteSealedEpisode(_ episode: BehavioralEpisode) {
        if episode.provenance.lane != "proactive" {
            lastUserEpisodeAtBox.withLock { $0 = Date() }
        }
        guard lifeEnabledBox.withLock({ $0 }) else { return }
        Task { await considerTrain(episode) }
    }

    static func startLifeLoopIfNeeded() {
        lifeEnabledBox.withLock { $0 = true }
        lifeLoopBox.withLock { task in
            guard task == nil else { return }
            task = Task { await runLifeLoop() }
        }
    }

    static func installLifeLoRALookup() async {
        await brain.setLifeLoRALookup { id in
            lifeSlotsBox.withLock { $0[id] }
        }
    }

    package static func refreshReadyLoRAs() async {
        let totemID = totemNodeIDBox.withLock { $0 }
        guard !totemID.isEmpty else { return }
        do {
            let slots = try await makeFleetClient().listAdapters(totemID: totemID)
            let mapped = Dictionary(uniqueKeysWithValues: slots.map { slot -> (AbilityID, LifeLoRASlot) in
                let id = AbilityID(slot.abilityID)
                return (id, LifeLoRASlot(
                    abilityID: id,
                    generation: slot.generation,
                    pairCount: slot.pairCount,
                    artifactPath: slot.artifactPath,
                    schemaJSON: slot.schemaJSON,
                    ready: slot.ready,
                    trainedAt: slot.trainedAt,
                    training: slot.training,
                    modelID: slot.modelID,
                    cid: slot.cid))
            })
            lifeSlotsBox.withLock { $0 = mapped }
            fleetReachableBox.withLock { $0 = true }
        } catch {
            fleetReachableBox.withLock { $0 = false }
            lifeLog.debug("listAdapters: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cheap overlay flag: a train is claimed, streaming, or listed as in flight.
    package static func lifeIsTraining() -> Bool {
        if !trainingDisciplinesBox.withLock({ $0.isEmpty }) { return true }
        if !lifeTrainProgressBox.withLock({ $0.isEmpty }) { return true }
        return lifeSlotsBox.withLock { $0.values.contains(where: \.training) }
    }

    /// Join installed disciplines, Totem episode counts, and in-memory Fleet
    /// slots. Does not dial Fleet or Totem — call `refreshReadyLoRAs` and
    /// `refreshBehaviorEpisodesFromTotem` when the sheet opens.
    package static func lifeCalibration() async -> LifeCalibrationSnapshot {
        let disciplines = LifeCalibration.disciplines(
            in: AbilityLibrary.shared.snapshot().records.map(\.package))
        let episodes = behaviorEpisodesBox.withLock { $0 }
        let slots = lifeSlotsBox.withLock { $0 }
        let ticks = lifeTrainProgressBox.withLock { $0 }
        let tails = lifeTrainTailBox.withLock { $0 }
        let reachable = fleetReachableBox.withLock { $0 }
        return LifeCalibration.snapshot(
            disciplines: disciplines,
            episodes: episodes,
            slots: slots,
            ticks: ticks,
            tails: tails,
            fleetReachable: reachable)
    }

    /// Pull Ability-lane behavior documents into the calibration cache.
    /// A failed export leaves the previous cache in place.
    package static func refreshBehaviorEpisodesFromTotem() async {
        guard let episodes = await totemContext.exportBehaviorEpisodes() else { return }
        behaviorEpisodesBox.withLock { $0 = episodes }
    }

    package static func behaviorEpisode(id: UUID) async -> BehavioralEpisode? {
        await totemContext.episode(id: id)
    }

    static func clearBehaviorEpisodeCache() {
        behaviorEpisodesBox.withLock { $0 = [] }
    }

    static func considerTrain(_ episode: BehavioralEpisode) async {
        let disciplines = Set(
            episode.abilityTargets.filter { $0.paradigm == .discipline }.map(\.abilityID))
        guard !disciplines.isEmpty else { return }
        guard let owner = await seerSession.userID else { return }
        await refreshReadyLoRAs()
        await refreshBehaviorEpisodesFromTotem()
        let episodes = behaviorEpisodesBox.withLock { $0 }
        let totemID = totemNodeIDBox.withLock { $0 }
        guard !totemID.isEmpty else { return }
        let fleet = makeFleetClient()
        for abilityID in disciplines {
            let completed = LifeTrainPolicy.completedCount(
                in: episodes, abilityID: abilityID)
            let slot = lifeSlotsBox.withLock { $0[abilityID] }
            let trained = slot.map(\.pairCount)
            guard LifeTrainPolicy.shouldTrain(
                completedCount: completed, trainedPairCount: trained)
            else { continue }
            guard slot?.training != true else { continue }
            let claimed = trainingDisciplinesBox.withLock {
                $0.insert(abilityID.rawValue).inserted
            }
            guard claimed else { continue }
            let groupIDs = Array(Set(
                episode.abilityTargets
                    .filter { $0.abilityID == abilityID && $0.paradigm == .discipline }
                    .map { TotemMemoryTopology.abilityGroup(target: $0, ownerID: owner).id }
            ))
            guard !groupIDs.isEmpty else {
                trainingDisciplinesBox.withLock { _ = $0.remove(abilityID.rawValue) }
                continue
            }
            Task {
                defer {
                    trainingDisciplinesBox.withLock { _ = $0.remove(abilityID.rawValue) }
                }
                do {
                    let stream = await fleet.train(
                        totemID: totemID,
                        abilityID: abilityID.rawValue,
                        modelID: MaryLocalEngine.defaultModelID,
                        ownerID: owner,
                        groupIDs: groupIDs)
                    for try await progress in stream {
                        noteTrainProgress(abilityID, progress)
                        if progress.stage == "finished" {
                            lifeLog.info(
                                "trained \(abilityID.rawValue, privacy: .public)")
                            clearTrainProgress(abilityID)
                            await refreshReadyLoRAs()
                        } else if progress.stage == "error" {
                            lifeLog.error(
                                "train \(abilityID.rawValue, privacy: .public): \(progress.message, privacy: .public)")
                            clearTrainProgress(abilityID)
                        }
                    }
                } catch {
                    clearTrainProgress(abilityID)
                    lifeLog.error(
                        "train \(abilityID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private static func runLifeLoop() async {
        let source = AmbientIdlePulseSource()
        await installLifeLoRALookup()
        await refreshBehaviorEpisodesFromTotem()
        while !Task.isCancelled {
            await refreshReadyLoRAs()
            let ready = lifeSlotsBox.withLock {
                Set($0.compactMap { $0.value.ready ? $0.key : nil })
            }
            let conditions = AmbientIdlePulse.Conditions(
                isTurnInFlight: await brain.hasOpenTurn,
                isSkillRunning: await brain.isBusy,
                isWorkspaceIndexing: await unitIndexer.hasPendingIdle,
                lastUserEpisodeAt: lastUserEpisodeAtBox.withLock { $0 },
                now: Date())
            let pulse = await source.beginIfReady(
                conditions: conditions,
                store: AmbientContextStore.shared,
                profiles: applicationProfiles(),
                readyDisciplines: ready)
            if let pulse {
                await dispatchLife(pulse)
                await source.endPulse()
            }
            let ns = UInt64(await source.period * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    private static func dispatchLife(_ pulse: AmbientIdlePulse) async {
        guard let hint = pulse.abilityHint,
              let slot = lifeSlotsBox.withLock({ $0[hint.abilityID] }),
              slot.ready
        else { return }
        do {
            let output = try await brain.completeCodec(
                input: pulse.input,
                schemaJSON: slot.schemaJSON,
                adapterPath: URL(fileURLWithPath: slot.artifactPath))
            let episode = output.makeEpisode(
                id: UUID(),
                input: pulse.input.makeInput(),
                provenance: EpisodeProvenance(
                    engine: "local",
                    lane: "proactive",
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        ?? "dev"),
                abilityTargets: [hint])
            await brain.runProactiveLife(episode: episode)
        } catch {
            lifeLog.error(
                "idle pulse dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func noteTrainProgress(_ abilityID: AbilityID, _ progress: FleetTrainProgress) {
        let tick = LifeTrainTick(
            stage: progress.stage,
            iteration: progress.iteration,
            loss: progress.loss,
            message: progress.message)
        lifeTrainProgressBox.withLock { $0[abilityID] = tick }
        lifeTrainTailBox.withLock { tails in
            var tail = tails[abilityID] ?? []
            tail.append(tick.line)
            if tail.count > 6 { tail.removeFirst(tail.count - 6) }
            tails[abilityID] = tail
        }
    }

    private static func clearTrainProgress(_ abilityID: AbilityID) {
        lifeTrainProgressBox.withLock { $0.removeValue(forKey: abilityID) }
    }
}
