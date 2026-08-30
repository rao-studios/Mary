//
//  LifeTrainPolicy.swift
//  MaryFoundation
//
//  When a discipline has earned a LoRA, and when it has earned another.
//  Tesla-calibration-shaped: first train at 24 completed episodes, then
//  every +12 new completed rows since the last published pair_count.
//

import Foundation

public enum LifeTrainPolicy: Sendable {
    public static let firstTrainCount = 24
    public static let retrainDelta = 12

    /// How far a discipline is through the current calibration window.
    /// After a publish, `filled` is new completed rows toward `retrainDelta`
    /// (zero while idle at the last pair_count — the bar reads full ready).
    public struct Fill: Sendable, Equatable {
        public var filled: Int
        public var goal: Int
        public var fraction: Double

        public init(filled: Int, goal: Int, fraction: Double) {
            self.filled = filled
            self.goal = goal
            self.fraction = fraction
        }
    }

    public static func progress(completedCount: Int, trainedPairCount: Int?) -> Fill {
        let goal = trainedPairCount == nil ? firstTrainCount : retrainDelta
        let raw: Int
        if let trained = trainedPairCount {
            raw = max(0, completedCount - trained)
        } else {
            raw = max(0, completedCount)
        }
        let filled = min(raw, goal)
        let fraction = goal == 0 ? 0 : Double(filled) / Double(goal)
        return Fill(filled: filled, goal: goal, fraction: fraction)
    }

    /// `trainedPairCount` is the last published manifest's pair_count; nil
    /// means this discipline has never trained.
    public static func shouldTrain(completedCount: Int, trainedPairCount: Int?) -> Bool {
        if let trained = trainedPairCount {
            return completedCount >= trained + retrainDelta
        }
        return completedCount >= firstTrainCount
    }

    public static func completedCount(
        in episodes: [BehavioralEpisode], abilityID: AbilityID
    ) -> Int {
        episodes.filter { episode in
            episode.sealedReason == .completed
                && episode.abilityTargets.contains {
                    $0.abilityID == abilityID && $0.paradigm == .discipline
                }
        }.count
    }

    /// Acted rows first so the output schema is non-empty; silent rows after
    /// so restraint is learnable.
    public static func trainingEpisodes(
        from episodes: [BehavioralEpisode], abilityID: AbilityID
    ) -> [BehavioralEpisode] {
        let eligible = episodes.filter { episode in
            episode.sealedReason == .completed
                && episode.abilityTargets.contains {
                    $0.abilityID == abilityID && $0.paradigm == .discipline
                }
        }
        let acted = eligible.filter(\.didAct)
        guard !acted.isEmpty else { return [] }
        return acted + eligible.filter { !$0.didAct }
    }
}
