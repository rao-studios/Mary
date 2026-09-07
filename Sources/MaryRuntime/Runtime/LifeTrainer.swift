//
//  LifeTrainer.swift
//  MaryRuntime
//
//  WHAT: When a discipline has earned a LoRA, and the one Fleet run that
//        gives it one. Owns claims, the queue, and the progress tail.
//  IN:   sealed episodes (MaryRuntime.noteSealedEpisode)
//  OUT:  Fleet train stream → LifeTrainTick; adapters refreshed on finish
//  PIN:  ONE TRAINING AT A TIME. Each run loads a base model in Fleet's
//        process; two at once is two model loads competing for the same GPU.
//
import Foundation
import MaryBrain
import MaryFoundation
import MaryTotem
import os

package actor LifeTrainer {

    /// A discipline waiting its turn, with everything the run needs.
    private struct Job: Equatable {
        var abilityID: AbilityID
        var ownerID: String
        var totemID: String
        var groupIDs: [String]
    }

    private var queue: [Job] = []
    /// Claimed disciplines — queued or running. Never two rows for one.
    private var claimed: Set<AbilityID> = []
    private var running: AbilityID?
    private var progress: [AbilityID: LifeTrainTick] = [:]
    private var tails: [AbilityID: [String]] = [:]
    private var pump: Task<Void, Never>?

    /// Refreshed adapters after a run finishes — the engine re-reads Fleet.
    private let onFinished: @Sendable (AbilityID) async -> Void

    private let log = Logger(subsystem: "nyc.rao.mary", category: "life")

    package init(onFinished: @escaping @Sendable (AbilityID) async -> Void) {
        self.onFinished = onFinished
    }

    // MARK: - Monitoring

    package func ticks() -> [AbilityID: LifeTrainTick] { progress }
    package func logTails() -> [AbilityID: [String]] { tails }
    package func isTraining() -> Bool { running != nil || !queue.isEmpty }
    package func inFlight() -> AbilityID? { running }

    // MARK: - The threshold

    /// Every completed discipline episode may trip a train. Proactive
    /// episodes never do — see `LifeTrainPolicy.completedCount`.
    package func consider(
        episode: BehavioralEpisode,
        episodes: [BehavioralEpisode],
        slots: [AbilityID: LifeLoRASlot],
        ownerID: String,
        totemID: String
    ) {
        let id = BehavioralAssembler.shortID(episode.id)
        let disciplines = Set(
            episode.abilityTargets.filter { $0.paradigm == .discipline }.map(\.abilityID))
        guard !disciplines.isEmpty else {
            note("train skipped \(id) — no discipline")
            return
        }
        for abilityID in disciplines.sorted(by: { $0.rawValue < $1.rawValue }) {
            let completed = LifeTrainPolicy.completedCount(
                in: episodes, abilityID: abilityID)
            let slot = slots[abilityID]
            let trained = slot.map(\.pairCount)
            let goal = trained.map { $0 + LifeTrainPolicy.retrainDelta }
                ?? LifeTrainPolicy.firstTrainCount
            guard LifeTrainPolicy.shouldTrain(
                completedCount: completed, trainedPairCount: trained)
            else {
                note("train skipped \(abilityID.rawValue) — \(completed)/\(goal) completed")
                continue
            }
            guard slot?.training != true else {
                note("train skipped \(abilityID.rawValue) — Fleet says training")
                continue
            }
            guard !claimed.contains(abilityID) else {
                note("train skipped \(abilityID.rawValue) — already claimed")
                continue
            }
            let groupIDs = Array(Set(
                episode.abilityTargets
                    .filter { $0.abilityID == abilityID && $0.paradigm == .discipline }
                    .map { TotemMemoryTopology.abilityGroup(target: $0, ownerID: ownerID).id }
            ))
            guard !groupIDs.isEmpty else {
                note("train skipped \(abilityID.rawValue) — no group")
                continue
            }
            claimed.insert(abilityID)
            queue.append(Job(
                abilityID: abilityID, ownerID: ownerID,
                totemID: totemID, groupIDs: groupIDs))
            note("train queued \(abilityID.rawValue) — groups \(groupIDs.count)")
        }
        startPumpIfNeeded()
    }

    // MARK: - The run

    private func startPumpIfNeeded() {
        guard pump == nil, !queue.isEmpty else { return }
        pump = Task { [weak self] in
            await self?.drain()
            await self?.clearPump()
        }
    }

    private func clearPump() {
        pump = nil
        startPumpIfNeeded()
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let job = queue.removeFirst()
            running = job.abilityID
            await run(job)
            running = nil
            claimed.remove(job.abilityID)
        }
    }

    private func run(_ job: Job) async {
        let fleet = MaryRuntime.makeFleetClient()
        note("train \(job.abilityID.rawValue) — started")
        do {
            let stream = await fleet.train(
                totemID: job.totemID,
                abilityID: job.abilityID.rawValue,
                modelID: LifeBaseModel.defaultModelID,
                ownerID: job.ownerID,
                groupIDs: job.groupIDs)
            for try await tick in stream {
                noteProgress(job.abilityID, tick)
                if tick.stage == "finished" {
                    log.info("trained \(job.abilityID.rawValue, privacy: .public)")
                    clearProgress(job.abilityID)
                    await onFinished(job.abilityID)
                } else if tick.stage == "error" {
                    log.error(
                        "train \(job.abilityID.rawValue, privacy: .public): \(tick.message, privacy: .public)")
                    clearProgress(job.abilityID)
                }
            }
        } catch {
            clearProgress(job.abilityID)
            log.error(
                "train \(job.abilityID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func noteProgress(_ abilityID: AbilityID, _ tick: FleetTrainProgress) {
        let value = LifeTrainTick(
            stage: tick.stage,
            iteration: tick.iteration,
            loss: tick.loss,
            message: tick.message)
        progress[abilityID] = value
        var tail = tails[abilityID] ?? []
        tail.append(value.line)
        if tail.count > 6 { tail.removeFirst(tail.count - 6) }
        tails[abilityID] = tail
    }

    private func clearProgress(_ abilityID: AbilityID) {
        progress.removeValue(forKey: abilityID)
    }

    private func note(_ line: String) {
        BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
    }
}
