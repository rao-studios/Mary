//
//  StyleObservation.swift
//  MaryAmbient
//
//  WHAT: One file's vote on one style dimension.
//  IN:   StyleProducer
//  OUT:  StyleEvidence
//  PIN:  Contract sits beside the store, not inside one producer.
//
import Foundation
import MaryFoundation

public struct StyleObservation: Sendable, Equatable {
    public var dimension: StyleDimension
    public var value: StyleValue
    /// How many instances this file contributed. A file with thirty lock boxes is stronger
    /// evidence than one with a single one — and the store clamps the influence of any single
    /// file, so one enormous source cannot decide a dimension by itself.
    public var weight: Int
    /// Bounded word list, for `roleVocabulary` only: the dimension whose
    /// answer is a vocabulary rather than a choice between alternatives.
    public var vocabulary: [String]

    public init(
        dimension: StyleDimension,
        value: StyleValue,
        weight: Int,
        vocabulary: [String] = []
    ) {
        self.dimension = dimension
        self.value = value
        self.weight = weight
        self.vocabulary = vocabulary
    }
}
