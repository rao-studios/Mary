//
//  SemanticSeedFamilyIndex.swift
//  MaryBrain
//
//  WHAT: Named families of authored sentences — the shapes of speech that are
//        neither an intent nor a Skill, but that the turn still must recognize.
//  IN:   `ability.triggers.seedFamilies` (authored package data)
//  OUT:  AmbientRanker.namesTransform, and whatever family comes next
//  PIN:  ONE FAMILY, BOTH SIDES. "tighten this up" (the user asking) and
//        "want me to tighten it up?" (Mary offering) are the same family; what
//        makes the second an OFFER is the question mark its caller checks, not
//        a second vocabulary.
//        NO BUILT-IN SEEDS. Unlike `SemanticIntentIndex`'s converse baseline,
//        every family here is owned by a package: a craft knows how its own
//        work is asked for, and nothing in Swift should be guessing.
//
import MaryAmbient
import MaryFoundation
import Foundation

public struct SemanticSeedFamilyIndex: Sendable {

    /// Cosine at or above this joins the family. Starts level with every other
    /// seam's floor; moved only on a calibration measurement.
    public static let floor: Float = 0.62

    /// The families the Brain actually consults. A package may author any key;
    /// one nothing reads is dead corpus, which `SeedFamilyFixtureTests` reports.
    public static let transform = "transform"
    public static let knownFamilies: Set<String> = [transform]

    private let families: [String: [[Float]]]
    private let vectorizer: any UtteranceVectorizer

    public var familyCount: Int { families.count }
    public func seedCount(_ family: String) -> Int { families[family]?.count ?? 0 }

    /// Nil when nothing vectorized — an index that can only say "no" would
    /// silently answer for a family it holds no seeds of.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer
    ) -> SemanticSeedFamilyIndex? {
        var families: [String: [[Float]]] = [:]
        var skipped = 0
        for record in records {
            for (family, seeds) in record.package.ability.triggers.seedFamilies {
                for seed in seeds where !seed.isEmpty {
                    guard let raw = vectorizer.vector(for: seed) else {
                        skipped += 1
                        continue
                    }
                    families[family, default: []].append(AmbientVectorMath.normalized(raw))
                }
            }
        }
        guard !families.isEmpty else { return nil }
        let summary = families
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        MaryBrain.turnLog.info(
            "embed generate — families \(summary, privacy: .public) skipped=\(skipped, privacy: .public)")
        return SemanticSeedFamilyIndex(families: families, vectorizer: vectorizer)
    }

    private init(families: [String: [[Float]]], vectorizer: any UtteranceVectorizer) {
        self.families = families
        self.vectorizer = vectorizer
    }

    /// Best cosine against the family, or nil when the family holds no seeds
    /// or the text does not vectorize. NIL IS NOT ZERO: a caller must be able
    /// to tell "scored badly" from "could not be scored".
    public func bestScore(_ family: String, in text: String) -> Float? {
        guard let seeds = families[family], !seeds.isEmpty,
              let raw = vectorizer.vector(for: RoutingQuery.firstLine(text))
        else { return nil }
        let needle = AmbientVectorMath.normalized(raw)
        return seeds.map { AmbientVectorMath.dot($0, needle) }.max()
    }

    public func matches(
        _ family: String, in text: String, floor: Float = floor
    ) -> Bool {
        (bestScore(family, in: text) ?? -1) >= floor
    }
}
