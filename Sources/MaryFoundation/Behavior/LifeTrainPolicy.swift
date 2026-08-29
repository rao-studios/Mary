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
