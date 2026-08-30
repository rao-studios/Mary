//
//  AmbientTextVectorizer.swift
//  MaryAmbient
//
//  WHAT: Text → vector. The seam every embedding consumer shares.
//  OUT:  AmbientElementIndex / MaryBrain ability-request index (typealias)
//  PIN:  Synchronous and cheap. Fail closed when OS has no English embedding.
//        CI injects fakes; real NLEmbedding is opt-in calibration only.
//
import Foundation
import NaturalLanguage
import os

/// Turns text into a fixed-dimension vector, or nil when it cannot — the
/// injectable seam that keeps similarity testable.
public protocol AmbientTextVectorizer: Sendable {
    func vector(for text: String) -> [Float]?
}

/// The production vectorizer: Apple's on-device sentence embedding, with the
/// word embedding as fallback (averaged over words). Loaded once; both
/// `NLEmbedding` handles live behind a lock because the class is not Sendable.
public struct NLAmbientTextVectorizer: AmbientTextVectorizer {

    /// Nil when the OS ships no English embedding asset — callers skip
    /// index construction entirely and their seams stay lexical-only.
    public static let shared: NLAmbientTextVectorizer? = {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil
            || NLEmbedding.wordEmbedding(for: .english) != nil
        else { return nil }
        return NLAmbientTextVectorizer()
    }()

    private struct Handles {
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        let word = NLEmbedding.wordEmbedding(for: .english)
    }

    private static let handles = OSAllocatedUnfairLock(initialState: Handles())

    public func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return Self.handles.withLock { handles -> [Float]? in
            if let sentence = handles.sentence,
               let vector = sentence.vector(for: trimmed) {
                return vector.map(Float.init)
            }
            guard let word = handles.word else { return nil }
            let words = trimmed
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            var sum: [Double]?
            var counted = 0
            for token in words {
                guard let vector = word.vector(for: token) else { continue }
                if var accumulated = sum {
                    for index in accumulated.indices { accumulated[index] += vector[index] }
                    sum = accumulated
                } else {
                    sum = vector
                }
                counted += 1
            }
            guard let sum, counted > 0 else { return nil }
            return sum.map { Float($0 / Double(counted)) }
        }
    }
}

/// Shared vector arithmetic for every embedding index in the ambient world.
public enum AmbientVectorMath {

    public static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    public static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return -1 }
        var total: Float = 0
        for index in lhs.indices { total += lhs[index] * rhs[index] }
        return total
    }
}
