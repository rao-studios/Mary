//
//  StyleObservation.swift
//  MaryAmbient
//
//  ONE FILE'S VOTE ON ONE DIMENSION — what a producer hands the evidence
//  store.
//
//  IT LIVES HERE RATHER THAN WITH THE PRODUCER, and that is the whole reason
//  it is a type at all. In the build this ports from it was a private struct
//  inside a compiled, language-named observer, which meant the ONE shape
//  every producer must speak was owned by the only producer that existed. A
//  second one — a different notation, a different application — had nowhere
//  to put its answers except a fourth loose-parameter call into the store.
//
//  Sitting beside `StyleEvidence`, it is the contract: a producer reads
//  whatever it reads however it likes, and says what it found in this shape.
//

import Foundation
import MaryFoundation

public struct StyleObservation: Sendable, Equatable {
    public var dimension: StyleDimension
    public var value: StyleValue
    /// How many instances this file contributed. A file with thirty lock
    /// boxes is stronger evidence than one with a single one — and the store
    /// clamps the influence of any single file, so one enormous source cannot
    /// decide a dimension by itself.
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
