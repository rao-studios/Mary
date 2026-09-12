//
//  LifeTrainPolicy.swift
//  MaryFoundation
//
//  WHAT: When a discipline has earned a LoRA, when it has earned another, and
//        which turns a run learns from.
//  IN:   completed episodes; when the published adapter trained.
//  OUT:  MaryRuntime+Life, LifeTrainer, LifeCalibration.
//  PIN:  A RUN LEARNS FROM THE LATEST 24 TURNS, not every turn so far. The
//        window rolls: each new turn pushes the oldest out. First train when
//        the window is full; retrain after 12 new turns since the last run.
//

import Foundation

public enum LifeTrainPolicy: Sendable {
    /// How many of a discipline's newest completed turns a run learns from.
    public static let windowSize = 24
    /// The first adapter waits for a full window.
    public static let firstTrainCount = windowSize
    /// New turns since the last run that earn a retrain.
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

    /// `newSinceTrain` is the turns completed since the published adapter
    /// trained; nil = never trained. The bar stops at its goal — past it the
    /// window just rolls.
    public static func progress(completedCount: Int, newSinceTrain: Int?) -> Fill {
        let goal = newSinceTrain == nil ? firstTrainCount : retrainDelta
        let filled = min(max(0, newSinceTrain ?? completedCount), goal)
        let fraction = goal == 0 ? 0 : Double(filled) / Double(goal)
        return Fill(filled: filled, goal: goal, fraction: fraction)
    }

    /// `newSinceTrain` as in `progress`.
    public static func shouldTrain(completedCount: Int, newSinceTrain: Int?) -> Bool {
        if let newSinceTrain {
            return newSinceTrain >= retrainDelta
        }
        return completedCount >= firstTrainCount
    }

    /// The turns a run learns from: this discipline's newest `windowSize`
    /// trainable episodes, oldest first.
    public static func window(
        _ episodes: [BehavioralEpisode], abilityID: AbilityID
    ) -> [BehavioralEpisode] {
        let trainable = episodes
            .filter { isTrainable($0, abilityID: abilityID) }
            .sorted { sealTime($0) < sealTime($1) }
        return Array(trainable.suffix(windowSize))
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

    /// Trainable turns sealed after `date` — the new turns a retrain waits for.
    public static func completedCount(
        in episodes: [BehavioralEpisode], abilityID: AbilityID, after date: Date
    ) -> Int {
        episodes.filter { isTrainable($0, abilityID: abilityID) && sealTime($0) > date }.count
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

    private static func sealTime(_ episode: BehavioralEpisode) -> Date {
        episode.sealedAt ?? episode.openedAt
    }
}
