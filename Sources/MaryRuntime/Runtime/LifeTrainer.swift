//
//  LifeTrainer.swift
//  MaryRuntime
//
//  WHAT: When a discipline has earned a LoRA, and the one Fleet run that
//        gives it one. Owns claims, the queue, and the progress tail.
//  IN:   sealed episodes (MaryRuntime.noteSealedEpisode); Life turning on
//  OUT:  Fleet train stream → LifeTrainTick; adapters refreshed on finish
//  PIN:  ONE TRAINING AT A TIME. Each run loads a base model in Fleet's
//        process; two at once is two model loads competing for the same GPU.
//  PIN:  PAUSED WHILE LIFE IS OFF. Nothing is queued or started; the windows
//        keep rolling, so the run after Life turns on learns from the
//        latest turns.
//  PIN:  MARY SENDS THE WINDOW. A run's pairs are the discipline's latest
//        24 turns, projected here — byte for byte what Fleet's own projector
//        makes (parity-tested on both sides) — so Fleet never exports the
//        whole corpus to train on part of it.
//
import Foundation
import MaryBrain
import MaryFoundation
import MaryThread
import os

package actor LifeTrainer {

    /// One discipline's run waiting its turn, with everything it needs.
    private struct Job {
        var abilityID: AbilityID
        var ownerID: String
        var threadID: String
        /// The window, as Fleet's training pairs.
        var pairs: [(inputJSON: String, outputJSON: String)]
    }

    private var queue: [Job] = []
    /// Claimed disciplines — queued or running. Never two rows for one.
    private var claimed: Set<AbilityID> = []
    private var running: AbilityID?
    private var progress: [AbilityID: LifeTrainTick] = [:]
    private var tails: [AbilityID: [String]] = [:]
    private var pump: Task<Void, Never>?

    /// True while Life is off: nothing is queued or started.
    private let isPaused: @Sendable () -> Bool
    /// Refreshed adapters after a run finishes — the engine re-reads Fleet.
    private let onFinished: @Sendable (AbilityID) async -> Void

    private let log = Logger(subsystem: "nyc.rao.mary", category: "life")

    package init(
        isPaused: @escaping @Sendable () -> Bool = { false },
        onFinished: @escaping @Sendable (AbilityID) async -> Void
    ) {
        self.isPaused = isPaused
        self.onFinished = onFinished
    }

    // MARK: - Monitoring

    package func ticks() -> [AbilityID: LifeTrainTick] { progress }
    package func logTails() -> [AbilityID: [String]] { tails }
    package func isTraining() -> Bool { running != nil || !queue.isEmpty }
    package func inFlight() -> AbilityID? { running }

    // MARK: - The threshold

    /// A sealed turn may earn a run in each discipline it targeted. Proactive
    /// episodes never do — see `LifeTrainPolicy.completedCount`.
    package func consider(
        episode: BehavioralEpisode,
        episodes: [BehavioralEpisode],
        slots: [AbilityID: LifeLoRASlot],
        ownerID: String,
        threadID: String
    ) {
        let id = BehavioralAssembler.shortID(episode.id)
        let disciplines = Set(
            episode.abilityTargets.filter { $0.paradigm == .discipline }.map(\.abilityID))
        guard !disciplines.isEmpty else {
            note("train skipped \(id) — no discipline")
            return
        }
        consider(
            disciplines: disciplines.sorted(by: { $0.rawValue < $1.rawValue }),
            episodes: episodes,
            slots: slots,
            ownerID: ownerID,
            threadID: threadID)
    }

    /// Check each discipline's window and queue the ones that have earned a
    /// run — what a sealed turn does for its disciplines, and what turning
    /// Life on does for all of them.
    package func consider(
        disciplines: [AbilityID],
        episodes: [BehavioralEpisode],
        slots: [AbilityID: LifeLoRASlot],
        ownerID: String,
        threadID: String
    ) {
        guard !isPaused() else {
            note("train skipped — Life is off; windows keep their latest \(LifeTrainPolicy.windowSize) turns")
            return
        }
        for abilityID in disciplines {
            let slot = slots[abilityID]
            let completed = LifeTrainPolicy.completedCount(in: episodes, abilityID: abilityID)
            let fresh = LifeCalibration.newSinceTrain(slot, episodes: episodes, abilityID: abilityID)
            guard LifeTrainPolicy.shouldTrain(completedCount: completed, newSinceTrain: fresh)
            else {
                let fill = LifeTrainPolicy.progress(completedCount: completed, newSinceTrain: fresh)
                note("train skipped \(abilityID.rawValue) — \(fill.filled)/\(fill.goal) completed")
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
            let pairs = Self.trainingPairs(LifeTrainPolicy.window(episodes, abilityID: abilityID))
            guard !pairs.isEmpty else {
                note("train skipped \(abilityID.rawValue) — no acted turn in the latest \(LifeTrainPolicy.windowSize)")
                continue
            }
            claimed.insert(abilityID)
            queue.append(Job(
                abilityID: abilityID, ownerID: ownerID, threadID: threadID, pairs: pairs))
            note("train queued \(abilityID.rawValue) — latest \(pairs.count) turns")
        }
        startPumpIfNeeded()
    }

    /// The window as Fleet's training pairs. Acted turns first, and at least
    /// one of them, the way Fleet orders a corpus it exports itself: the
    /// output schema is drawn from acted rows, and silent rows teach
    /// restraint. A turn with no query is dropped, as Fleet's projector
    /// drops it.
    static func trainingPairs(
        _ window: [BehavioralEpisode]
    ) -> [(inputJSON: String, outputJSON: String)] {
        var acted: [(inputJSON: String, outputJSON: String)] = []
        var silent: [(inputJSON: String, outputJSON: String)] = []
        for episode in window {
            let pair = BehavioralTrainingPair(episode: episode)
            guard !pair.input.query.isEmpty,
                  let input = try? pair.encodedInput(),
                  let output = try? pair.encodedOutput(),
                  let inputJSON = String(data: input, encoding: .utf8),
                  let outputJSON = String(data: output, encoding: .utf8)
            else { continue }
            if pair.output.actions.isEmpty {
                silent.append((inputJSON, outputJSON))
            } else {
                acted.append((inputJSON, outputJSON))
            }
        }
        guard !acted.isEmpty else { return [] }
        return acted + silent
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
            // Life went off after this was queued: drop it; its window keeps rolling.
            guard !isPaused() else {
                claimed.remove(job.abilityID)
                note("train dropped \(job.abilityID.rawValue) — Life is off")
                continue
            }
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
                threadID: job.threadID,
                abilityID: job.abilityID.rawValue,
                modelID: LifeBaseModel.defaultModelID,
                pairs: job.pairs,
                ownerID: job.ownerID,
                groupIDs: [])
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
