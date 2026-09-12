//
//  LifeCalibration.swift
//  MaryRuntime
//
//  WHAT: Snapshot the Life sheet polls — one row per installed discipline.
//  IN:   in-memory boxes (episodes, Fleet slots, train ticks). No Fleet/Thread dial.
//  OUT:  LifeCalibrationSnapshot → Life sheet
//  PIN:  Episode cache refresh: Life-loop start, Ability deposit, sheet open.
//  PIN:  New turns since a run are counted by time: a run learns from a fixed
//        window, so its pair count no longer says how many turns it saw.
//

import Foundation
import MaryBrain
import MaryFoundation

/// One streamed train event, stripped of MaryThread so the app never names Fleet.
package struct LifeTrainTick: Sendable, Equatable {
    package var stage: String
    package var iteration: Int
    package var loss: Float
    package var message: String

    package init(stage: String, iteration: Int, loss: Float, message: String) {
        self.stage = stage
        self.iteration = iteration
        self.loss = loss
        self.message = message
    }

    package var line: String {
        if !message.isEmpty { return "\(stage) · \(message)" }
        if stage == "step" {
            return String(format: "step %d · loss %.2f", iteration, loss)
        }
        return stage
    }
}

package struct LifeDisciplineStatus: Sendable, Equatable, Identifiable {
    package enum Phase: String, Sendable, Equatable {
        case collecting
        case training
        case ready
    }

    package var abilityID: AbilityID
    package var title: String
    package var completedCount: Int
    package var pairCount: Int?
    package var generation: Int
    package var ready: Bool
    package var training: Bool
    package var trainedAt: Date?
    package var modelID: String
    package var artifactPath: String
    package var schemaJSON: Data
    package var cid: String
    package var fill: LifeTrainPolicy.Fill
    package var latest: LifeTrainTick?
    package var logTail: [String]
    /// Life is off: nothing trains, and a full window rolls instead of growing.
    package var trainingPaused: Bool = false

    package var id: String { abilityID.rawValue }

    package var phase: Phase {
        if training { return .training }
        if ready, fill.filled == 0 { return .ready }
        return .collecting
    }

    /// Ready-and-idle / training: full bar. Collecting: window fraction.
    /// Training+loading: thin slice while Fleet copies.
    package var displayFraction: Double {
        switch phase {
        case .training:
            return latest?.stage == "loading" ? 0.12 : 1
        case .ready:
            return 1
        case .collecting:
            return fill.fraction
        }
    }

    package var caption: String {
        switch phase {
        case .training:
            guard let latest else { return "training" }
            if latest.stage == "step" {
                return String(
                    format: "training · step %d · loss %.2f",
                    latest.iteration, latest.loss)
            }
            if !latest.message.isEmpty { return "training · \(latest.message)" }
            return "training · \(latest.stage)"
        case .ready:
            let pairs = pairCount ?? 0
            return "ready · gen \(generation) · \(pairs) pair\(pairs == 1 ? "" : "s")"
        case .collecting:
            let base = pairCount == nil
                ? "\(fill.filled) of \(fill.goal) turns"
                : "\(fill.filled) of \(fill.goal) since gen \(generation)"
            // A full window with Life off doesn't grow; its oldest turn rolls off.
            return trainingPaused && fill.filled >= fill.goal ? base + " · paused" : base
        }
    }
}

package struct LifeCalibrationSnapshot: Sendable, Equatable {
    package var rows: [LifeDisciplineStatus]
    package var fleetReachable: Bool

    package init(rows: [LifeDisciplineStatus], fleetReachable: Bool) {
        self.rows = rows
        self.fleetReachable = fleetReachable
    }

    package var readyCount: Int { rows.filter { $0.phase == .ready }.count }
    package var isTraining: Bool { rows.contains { $0.phase == .training } }
}

package enum LifeCalibration {
    /// Installed `.discipline` packages only — expertise never gets a LoRA.
    package static func disciplines(
        in packages: [MaryAbilityPackage]
    ) -> [(id: AbilityID, title: String)] {
        packages
            .filter { $0.paradigm == .discipline }
            .map { (id: $0.ability.id, title: $0.ability.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Completed turns since the adapter behind `slot` trained; nil when
    /// there is no adapter.
    package static func newSinceTrain(
        _ slot: LifeLoRASlot?, episodes: [BehavioralEpisode], abilityID: AbilityID
    ) -> Int? {
        guard let slot else { return nil }
        guard let trainedAt = slot.trainedAt else {
            let completed = LifeTrainPolicy.completedCount(in: episodes, abilityID: abilityID)
            return max(0, completed - slot.pairCount)
        }
        return LifeTrainPolicy.completedCount(in: episodes, abilityID: abilityID, after: trainedAt)
    }

    package static func snapshot(
        disciplines: [(id: AbilityID, title: String)],
        episodes: [BehavioralEpisode],
        slots: [AbilityID: LifeLoRASlot],
        ticks: [AbilityID: LifeTrainTick],
        tails: [AbilityID: [String]],
        fleetReachable: Bool,
        trainingPaused: Bool = false
    ) -> LifeCalibrationSnapshot {
        let rows = disciplines.map { item -> LifeDisciplineStatus in
            let slot = slots[item.id]
            let tick = ticks[item.id]
            let completed = LifeTrainPolicy.completedCount(
                in: episodes, abilityID: item.id)
            let fresh = newSinceTrain(slot, episodes: episodes, abilityID: item.id)
            let trained = slot.map(\.pairCount)
            let isTraining = slot?.training == true
                || (tick != nil && tick?.stage != "finished" && tick?.stage != "error")
            return LifeDisciplineStatus(
                abilityID: item.id,
                title: item.title,
                completedCount: completed,
                pairCount: trained,
                generation: slot?.generation ?? 0,
                ready: slot?.ready ?? false,
                training: isTraining,
                trainedAt: slot?.trainedAt,
                modelID: slot?.modelID ?? "",
                artifactPath: slot?.artifactPath ?? "",
                schemaJSON: slot?.schemaJSON ?? Data(),
                cid: slot?.cid ?? "",
                fill: LifeTrainPolicy.progress(
                    completedCount: completed, newSinceTrain: fresh),
                latest: tick,
                logTail: tails[item.id] ?? [],
                trainingPaused: trainingPaused)
        }
        return LifeCalibrationSnapshot(rows: rows, fleetReachable: fleetReachable)
    }
}
