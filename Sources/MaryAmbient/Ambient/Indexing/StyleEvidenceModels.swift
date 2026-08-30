//
//  StyleEvidenceModels.swift
//  MaryAmbient
//
//  WHAT: StyleAccrualPolicy, StyleContribution, and StyleEvidenceRow.
//  IN:   StyleEvidence.swift (split)
//  OUT:  StyleEvidenceStore
//

import MaryFoundation
import Foundation

/// The knobs, in one readable place.
public struct StyleAccrualPolicy: Sendable, Equatable {
    /// DISTINCT SOURCES of the winning value needed before a tenet may be believed at all.
    public var minimumSupport: Int
    /// Proportion of evidence that must agree. Set where it is because a
    /// convention is not a convention if a third of the corpus disagrees.
    public var minimumAgreement: Double
    /// Below this, a verified tenet falls back to candidate. Deliberately
    /// lower than `minimumAgreement` so a tenet does not oscillate across the
    /// boundary on single observations.
    public var demotionAgreement: Double

    public init(
        minimumSupport: Int = 3,
        minimumAgreement: Double = 0.7,
        demotionAgreement: Double = 0.55
    ) {
        self.minimumSupport = minimumSupport
        self.minimumAgreement = minimumAgreement
        self.demotionAgreement = demotionAgreement
    }

    public static let standard = StyleAccrualPolicy()

    /// Confidence is agreement tempered by how much evidence there is, so a 2-of-2 tenet does
    /// not outrank a 40-of-45 one. It saturates rather than climbing forever, which is what
    /// stops a big corpus from producing certainty it has not earned.
    public func confidence(support: Int, counter: Int) -> Double {
        let total = support + counter
        guard total > 0 else { return 0 }
        let agreement = Double(support) / Double(total)
        let volume = min(1, Double(total) / 12)
        return min(1, agreement * (0.55 + 0.45 * volume))
    }

    public func status(
        support: Int, counter: Int, sources: Int, previous: StyleStatus
    ) -> StyleStatus {
        let total = support + counter
        guard total > 0 else { return .candidate }
        let agreement = Double(support) / Double(total)
        if sources >= minimumSupport, agreement >= minimumAgreement { return .verified }
        // The hysteresis deliberately asks nothing about sources: a restored snapshot is ONE
        // contribution however many files stood behind it, and a verified tenet must not demote
        // just for having been through a relaunch.
        if previous == .verified, agreement >= demotionAgreement { return .verified }
        return .candidate
    }
}

/// What ONE source currently says about one dimension. Keyed by source and REPLACED rather
/// than added, which is the whole point.
struct StyleContribution: Sendable, Equatable {
    var value: StyleValue
    var weight: Int
    var vocabulary: [String]
    /// The revision this came from, so a re-read of unchanged content is
    /// visibly the same evidence and a changed file is visibly new evidence.
    var sourceHash: String
    var at: Date
}

/// One dimension's tally at one scope, as a set of current opinions.
struct StyleEvidenceRow: Sendable, Equatable {
    var contributions: [String: StyleContribution] = [:]
    var status: StyleStatus = .candidate

    var lastObservedAt: Date {
        contributions.values.map(\.at).max() ?? .distantPast
    }

    var isEmpty: Bool { contributions.isEmpty }

    /// Recency-weighted totals per value.
    func tallies(at now: Date) -> [StyleValue: Double] {
        var totals: [StyleValue: Double] = [:]
        for contribution in contributions.values {
            let recency = StyleRecency.weight(at: contribution.at, now: now)
            // THE FLOOR IS APPLIED HERE AS WELL AS IN THE SWEEP, and it has to be.
            guard recency >= StyleRecency.decayFloor else { continue }
            totals[contribution.value, default: 0] += Double(contribution.weight) * recency
        }
        return totals
    }

    func vocabularyTallies(at now: Date) -> [String: Double] {
        var totals: [String: Double] = [:]
        for contribution in contributions.values {
            let recency = StyleRecency.weight(at: contribution.at, now: now)
            guard recency >= StyleRecency.decayFloor else { continue }
            // Weight matters here exactly as in `tallies`.
            for word in contribution.vocabulary {
                totals[word, default: 0] += Double(contribution.weight) * recency
            }
        }
        return totals
    }

    /// How many distinct sources currently stand behind `value` — the breadth
    /// measure promotion runs on, where `tallies` is the depth measure
    /// confidence runs on.
    func sources(of value: StyleValue, at now: Date) -> Int {
        contributions.values.filter {
            $0.value == value
                && StyleRecency.weight(at: $0.at, now: now) >= StyleRecency.decayFloor
        }.count
    }

    /// The leading value and the weight for and against it. Weighted totals round to integers
    /// only here, at the boundary where a tenet is minted — the live tally stays continuous so
    /// a slow drift is not lost to rounding on every observation.
    func leader(at now: Date) -> (value: StyleValue, support: Int, counter: Int)? {
        let totals = tallies(at: now).filter { $0.value > 0.0001 }
        let ranked = totals.sorted {
            $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
        }
        guard let top = ranked.first else { return nil }
        // A tie is not a leader. Silence beats inventing a preference the
        // corpus does not have.
        if ranked.count > 1, abs(ranked[1].value - top.value) < 0.0001 { return nil }
        let counter = ranked.dropFirst().reduce(0.0) { $0 + $1.value }
        // A leader that exists counts for at least 1. A single ageing contribution otherwise
        // rounds to support 0, `status` short-circuits to `.candidate` ignoring the hysteresis,
        // and `publish` LATCHES that — permanently demoting a tenet the evidence still supports.
        return (top.key, max(1, Int(top.value.rounded())), Int(counter.rounded()))
    }
}
