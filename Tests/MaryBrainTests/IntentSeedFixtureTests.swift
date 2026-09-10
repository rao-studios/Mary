//
//  IntentSeedFixtureTests.swift
//  MaryBrainTests
//
//  WHAT: A package's `intentSeeds` keys are real, eligible AmbientIntent
//        cases, and the whole corpus builds into a working index.
//  OUT:  AmbientIntent × package `triggers.intentSeeds`
//  PIN:  Validator cannot see AmbientIntent — this suite lives in Brain,
//        beside PackageRoutingFixtureTests, which makes the same call for
//        `intent` routing predicates.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct IntentSeedFixtureTests {

    private static func shippedPackages(_ abilities: URL) throws -> [MaryAbilityPackage] {
        try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try AbilityPackageCodec.load(from: $0) }
    }

    /// Every key any shipped package authors under `triggers.intentSeeds`
    /// resolves via `AmbientIntent(rawValue:)` AND is one of the intents
    /// `SemanticIntentIndex` will actually consult — `halt`/`decide`/`revise`/
    /// `architect` are deterministic or classifier-owned, so a seed under one
    /// of those keys can never be reached and is as dead as an unknown key.
    @Test func everyIntentSeedKeyIsRealAndEligible() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)
        #expect(!packages.isEmpty, "Abilities/ holds no .mary packages")

        for package in packages {
            for key in package.ability.triggers.intentSeeds.keys {
                let intent = AmbientIntent(rawValue: key)
                #expect(
                    intent != nil,
                    """
                    \(package.package.id.rawValue) declares intentSeeds for \
                    "\(key)", which is not an AmbientIntent case \
                    (\(AmbientIntent.allCases.map(\.rawValue).sorted().joined(separator: ", "))).
                    """)
                if let intent {
                    #expect(
                        SemanticIntentIndex.eligibleIntents.contains(intent),
                        """
                        \(package.package.id.rawValue) declares intentSeeds for \
                        "\(key)", which SemanticIntentIndex never classifies into \
                        (eligible: \(SemanticIntentIndex.eligibleIntents.map(\.rawValue).sorted().joined(separator: ", "))) \
                        — these seeds can never be reached.
                        """)
                }
            }
        }
    }

    /// No two shipped packages author the exact same sentence under
    /// different intents. A real embedding conflict (two DIFFERENT sentences
    /// that merely score close) is `SemanticIntentIndex.build`'s own
    /// `conflictCeiling` dedup to resolve at runtime; an identical sentence
    /// under two intents is unambiguous ambiguity — worth catching in the
    /// package, not silently dropped from both sides at build time.
    @Test func noShippedPackageSeedsConflictAtBuild() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)
        var seenUnderIntent: [String: String] = [:]
        for package in packages {
            for (key, terms) in package.ability.triggers.intentSeeds {
                for term in terms {
                    let folded = term.lowercased().trimmingCharacters(in: .whitespaces)
                    if let existing = seenUnderIntent[folded], existing != key {
                        Issue.record(
                            """
                            "\(term)" is seeded under both "\(existing)" and "\(key)" \
                            across shipped packages — ambiguous authoring.
                            """)
                    }
                    seenUnderIntent[folded] = key
                }
            }
        }
    }
}
