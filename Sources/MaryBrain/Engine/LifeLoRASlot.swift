//
//  LifeLoRASlot.swift
//  MaryBrain
//
//  The ready LoRA the turn may act through. Runtime fills this from Fleet;
//  Brain never dials Fleet itself.
//

import Foundation
import MaryFoundation

public struct LifeLoRASlot: Sendable, Equatable {
    public var abilityID: AbilityID
    public var generation: Int
    public var pairCount: Int
    public var artifactPath: String
    public var schemaJSON: Data
    public var ready: Bool
    public var trainedAt: Date?
    public var training: Bool

    public init(
        abilityID: AbilityID,
        generation: Int,
        pairCount: Int,
        artifactPath: String,
        schemaJSON: Data,
        ready: Bool,
        trainedAt: Date? = nil,
        training: Bool = false
    ) {
        self.abilityID = abilityID
        self.generation = generation
        self.pairCount = pairCount
        self.artifactPath = artifactPath
        self.schemaJSON = schemaJSON
        self.ready = ready
        self.trainedAt = trainedAt
        self.training = training
    }
}
