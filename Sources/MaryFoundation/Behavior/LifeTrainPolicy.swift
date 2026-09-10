//
//  LifeTrainPolicy.swift
//  MaryFoundation
//
//  WHAT: When a discipline has earned a LoRA, and when it has earned another.
//  IN:   completed episode counts / last published pair_count.
//  OUT:  MaryRuntime+Life, LifeLoRASlot.
//  PIN:  First train at 24 completed; then every +12 new completed rows.
//

import Foundation

public enum LifeTrainPolicy: Sendable {
    public static let firstTrainCount = 24
    public static let retrainDelta = 12

    /// Progress through the current window. After publish, `filled` is new rows toward `retrainDelta`.
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

    /// Last published pair_count; nil = never trained.
    public static func shouldTrain(completedCount: Int, trainedPairCount: Int?) -> Bool {
        if let trained = trainedPairCount {
            return completedCount >= trained + retrainDelta
        }
        return completedCount >= firstTrainCount
    }

    /// Turns THIS PERSON took, in this discipline, that finished.
    ///
    /// PIN: MARY'S OWN IDLE EPISODES DO NOT COUNT. They are sealed
    /// `.completed` and filed under the same ability group as a real turn, so
    /// without this filter a quiet afternoon of pulses would trip a retrain
    /// on the model's own output — and every generation after that would be
    /// learning from the last one instead of from the user.
    public static func completedCount(
        in episodes: [BehavioralEpisode], abilityID: AbilityID
    ) -> Int {
        episodes.filter { isTrainable($0, abilityID: abilityID) }.count
    }

    /// Whether one episode may teach this discipline anything.
    public static func isTrainable(
        _ episode: BehavioralEpisode, abilityID: AbilityID
    ) -> Bool {
        episode.sealedReason == .completed
            && !episode.provenance.isProactive
            && episode.abilityTargets.contains {
                $0.abilityID == abilityID && $0.paradigm == .discipline
            }
    }
}
