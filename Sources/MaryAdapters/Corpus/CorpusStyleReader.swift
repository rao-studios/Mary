//
//  CorpusStyleReader.swift
//  MaryAdapters
//
//  THE DECLARED RULES, RUN. One file in, a set of style observations out.
//
//  This is the interpreter that replaces a compiled, language-named observer:
//  the questions it asks come entirely from the package, and nothing in this
//  file knows what language it is reading or which application declared it.
//
//  A TIE IS SILENCE, and that is the rule worth stating loudest. A file with
//  equal evidence for two habits has no opinion about which one the author
//  has, and a coin flip recorded as evidence is worse than nothing — it is
//  noise that accumulates confidence over time. Everything below abstains
//  readily: a failed guard, a candidate under its minimum, a tie, an empty
//  file, a denominator of zero.
//
//  WEIGHT IS CLAMPED PER FILE. One enormous generated file must not outvote a
//  hundred hand-written ones, so no single file may contribute more than
//  `maximumWeightPerFile` to any dimension.
//

import Foundation
import MaryAmbient
import MaryFoundation

public enum CorpusStyleReader {

    /// The most one file may say about one dimension. A generated file is not
    /// how a person writes, and neither is the longest file in the project.
    public static let maximumWeightPerFile = 12

    /// Read one file through one corpus's declared rules.
    ///
    /// - Parameter declaredTypes: names this file declares, from the corpus's
    ///   own `declarations` probe — the cross-reference the `selfReference`
    ///   and `declaredTypeSuffix` counters need and a regex cannot make.
    public static func observe(
        text: CorpusText,
        declaredTypes: [String],
        corpus: PluginCorpusSchema
    ) -> [StyleObservation] {
        guard !text.source.isEmpty else { return [] }
        let declared = Set(declaredTypes)
        let declarationCount = corpus.relations.declarations.reduce(0) {
            $0 + CorpusPatterns.captures($1, in: text.code).count
        }

        var observations: [StyleObservation] = []
        for rule in corpus.style {
            guard let dimension = StyleDimension(rawValue: rule.dimension) else { continue }
            guard passes(
                rule.guardCondition, text: text, declared: declared,
                declarationCount: declarationCount)
            else { continue }

            switch rule.kind {
            case .vote:
                if let observation = vote(
                    rule, dimension: dimension, text: text, declared: declared,
                    declarationCount: declarationCount) {
                    observations.append(observation)
                }
            case .ratio:
                if let observation = ratio(
                    rule, dimension: dimension, text: text, declared: declared,
                    declarationCount: declarationCount) {
                    observations.append(observation)
                }
            case .vocabulary:
                if let observation = vocabulary(rule, dimension: dimension, declared: declaredTypes) {
                    observations.append(observation)
                }
            }
        }
        return observations.map {
            var clamped = $0
            clamped.weight = min(maximumWeightPerFile, max(1, $0.weight))
            return clamped
        }
    }

    // MARK: - Kinds

    private static func vote(
        _ rule: PluginCorpusStyleRule,
        dimension: StyleDimension,
        text: CorpusText,
        declared: Set<String>,
        declarationCount: Int
    ) -> StyleObservation? {
        var tallies: [(StyleValue, Int)] = []
        for candidate in rule.candidates {
            guard let value = StyleValue(rawValue: candidate.value) else { continue }
            let score = candidate.counters.reduce(0) {
                $0 + measure($1, text: text, declared: declared,
                             declarationCount: declarationCount)
            }
            // BELOW ITS FLOOR A CANDIDATE DOES NOT STAND. It scores zero
            // rather than a small number, because "one of the type's own
            // extensions" is not weak evidence that the author keeps types
            // whole — it is no evidence at all.
            tallies.append((value, score >= candidate.minimum ? score : 0))
        }
        return winner(dimension, tallies)
    }

    private static func ratio(
        _ rule: PluginCorpusStyleRule,
        dimension: StyleDimension,
        text: CorpusText,
        declared: Set<String>,
        declarationCount: Int
    ) -> StyleObservation? {
        guard let numeratorCounter = rule.numerator,
              let denominatorCounter = rule.denominator,
              let threshold = rule.threshold
        else { return nil }
        let numerator = measure(
            numeratorCounter, text: text, declared: declared,
            declarationCount: declarationCount)
        let denominator = measure(
            denominatorCounter, text: text, declared: declared,
            declarationCount: declarationCount)
        guard denominator > 0 else { return nil }

        let fraction = Double(numerator) / Double(denominator)
        // THE WEIGHT IS THE EVIDENCE ON THE WINNING SIDE, not the ratio: a
        // file with 40 of 60 declarations public says more about a public
        // habit than one with 2 of 3.
        if fraction > threshold {
            guard let above = rule.above, let value = StyleValue(rawValue: above) else { return nil }
            return StyleObservation(dimension: dimension, value: value, weight: numerator)
        }
        guard let below = rule.below, let value = StyleValue(rawValue: below) else { return nil }
        return StyleObservation(
            dimension: dimension, value: value, weight: max(1, denominator - numerator))
    }

    private static func vocabulary(
        _ rule: PluginCorpusStyleRule,
        dimension: StyleDimension,
        declared: [String]
    ) -> StyleObservation? {
        guard let counter = rule.vocabulary, counter.source == .declaredTypeSuffix else {
            return nil
        }
        var found: [String] = []
        for name in declared {
            for token in counter.tokens where name.hasSuffix(token) && name != token {
                found.append(token.lowercased())
            }
        }
        guard !found.isEmpty else { return nil }
        return StyleObservation(
            dimension: dimension, value: .unknown, weight: found.count, vocabulary: found)
    }

    // MARK: - Guards and counters

    private static func passes(
        _ condition: PluginCorpusGuard?,
        text: CorpusText,
        declared: Set<String>,
        declarationCount: Int
    ) -> Bool {
        guard let condition else { return true }
        let numerator = measure(
            condition.numerator, text: text, declared: declared,
            declarationCount: declarationCount)
        guard let denominatorCounter = condition.denominator else {
            return Double(numerator) >= condition.atLeast
        }
        let denominator = measure(
            denominatorCounter, text: text, declared: declared,
            declarationCount: declarationCount)
        // A DENOMINATOR OF ZERO FAILS THE GUARD rather than dividing. "How
        // dense is the commentary in a file with no declarations" has no
        // answer, and any number invented for it is a vote.
        guard denominator > 0 else { return false }
        return Double(numerator) / Double(denominator) >= condition.atLeast
    }

    private static func measure(
        _ counter: PluginCorpusCounter,
        text: CorpusText,
        declared: Set<String>,
        declarationCount: Int
    ) -> Int {
        switch counter.source {
        case .pattern:
            guard let pattern = counter.pattern else { return 0 }
            return CorpusPatterns.count(pattern, in: text.slice(counter.region))

        case .selfReference:
            guard let pattern = counter.pattern else { return 0 }
            return CorpusPatterns.captures(pattern, in: text.slice(counter.region))
                .filter(declared.contains)
                .count

        case .declaredTypeSuffix:
            return declared.reduce(0) { total, name in
                total + (counter.tokens.contains { name.hasSuffix($0) && name != $0 } ? 1 : 0)
            }

        case .declaration:
            return declarationCount

        case .fileBytes:
            return text.byteCount
        }
    }

    // MARK: - The winner

    /// The leading value, or nothing. A TIE IS DELIBERATELY SILENCE — see the
    /// file header.
    static func winner(
        _ dimension: StyleDimension, _ tallies: [(StyleValue, Int)]
    ) -> StyleObservation? {
        let ranked = tallies.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let leader = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].1 == leader.1 { return nil }
        return StyleObservation(dimension: dimension, value: leader.0, weight: leader.1)
    }
}
