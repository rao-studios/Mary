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
    private static let lifeLog = Logger(subsystem: "nyc.rao.mary", category: "life")

    /// Called from `BehavioralStore.append` after a seal. User turns stamp the
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

    static func refreshReadyLoRAs() async {
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
                    training: slot.training))
            })
            lifeSlotsBox.withLock { $0 = mapped }
        } catch {
            lifeLog.debug("listAdapters: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func considerTrain(_ episode: BehavioralEpisode) async {
        let disciplines = Set(
            episode.abilityTargets.filter { $0.paradigm == .discipline }.map(\.abilityID))
        guard !disciplines.isEmpty else { return }
        await refreshReadyLoRAs()
        let episodes = await behavioralStore.allEpisodes().episodes
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
            let rows = LifeTrainPolicy.trainingEpisodes(
                from: episodes, abilityID: abilityID)
            let pairs: [(String, String)] = rows.compactMap { row in
                let pair = BehavioralTrainingPair(episode: row)
                guard let input = try? String(data: pair.encodedInput(), encoding: .utf8),
                      let output = try? String(data: pair.encodedOutput(), encoding: .utf8)
                else { return nil }
                return (input, output)
            }
            guard !pairs.isEmpty else {
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
                        pairs: pairs)
                    for try await progress in stream {
                        if progress.stage == "finished" {
                            lifeLog.info(
                                "trained \(abilityID.rawValue, privacy: .public)")
                            await refreshReadyLoRAs()
                        } else if progress.stage == "error" {
                            lifeLog.error(
                                "train \(abilityID.rawValue, privacy: .public): \(progress.message, privacy: .public)")
                        }
                    }
                } catch {
                    lifeLog.error(
                        "train \(abilityID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private static func runLifeLoop() async {
        let source = AmbientIdlePulseSource()
        await installLifeLoRALookup()
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
}
