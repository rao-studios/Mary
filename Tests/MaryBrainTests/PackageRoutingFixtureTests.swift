//
//  PackageRoutingFixtureTests.swift
//  MaryBrainTests
//
//  WHAT: Package route fixtures actually fire; dead intent predicates are visible.
//  OUT:  AmbientIntent × package eligibility
//  PIN:  Validator cannot see AmbientIntent — this suite lives in Brain
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct PackageRoutingFixtureTests {

    private static func shippedPackages(_ abilities: URL) throws -> [MaryAbilityPackage] {
        try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try AbilityPackageCodec.load(from: $0) }
    }

    /// Every `intent` predicate anywhere in a package's routing — Ability-level
    /// or Skill-level, at any depth of `all`/`any`/`not` — names a real
    /// `AmbientIntent` case. Walked once and reused by both checks below.
    private static func intentValues(in predicate: RoutingPredicate) -> [String] {
        var values: [String] = []
        if predicate.kind == .intent, let value = predicate.value {
            values.append(value)
        }
        for child in predicate.children {
            values.append(contentsOf: intentValues(in: child))
        }
        return values
    }

    private static func allPredicates(in policy: RoutingPolicySchema) -> [RoutingPredicate] {
        (policy.eligibility.map { [$0] } ?? []) + policy.excludes
    }

    @Test func everyIntentPredicateNamesARealAmbientIntent() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)
        #expect(!packages.isEmpty, "Abilities/ holds no .mary packages")

        let knownIntents = Set(AmbientIntent.allCases.map(\.rawValue))
        for package in packages {
            let policies = [package.ability.routing] + package.skills.map(\.routing)
            for policy in policies {
                for predicate in Self.allPredicates(in: policy) {
                    for value in Self.intentValues(in: predicate) {
                        #expect(
                            knownIntents.contains(value),
                            """
                            \(package.package.id.rawValue) declares intent \
                            "\(value)", which is not an AmbientIntent case \
                            (\(AmbientIntent.allCases.map(\.rawValue).sorted().joined(separator: ", "))) \
                            — this predicate arm can never fire.
                            """)
                    }
                }
            }
        }
    }

    /// Whether a predicate tree names only the two kinds an `AbilityFixture`
    /// cannot possibly supply — `intent` and `workspaceFamily` both come out of
    /// a live turn's classifier and route arbitration, not out of a static
    /// utterance string. `writing.mary`'s eligibility leans on both and is
    /// correctly live in production; a fixture-only context has no way to
    /// prove or disprove that, so this check has to recognize the difference
    /// between "unprovable from here" and "provably dead" rather than
    /// reporting the former as the latter.
    private static func dependsOnRuntimeClassifiedContext(_ predicate: RoutingPredicate) -> Bool {
        if predicate.kind == .intent || predicate.kind == .workspaceFamily { return true }
        return predicate.children.contains(where: dependsOnRuntimeClassifiedContext)
    }

    /// Builds the routing context a `route` fixture claims, and checks the
    /// OWNING ABILITY's routing policy — the gate `expectedSkill` must pass
    /// before its Skill is even in the election — actually admits it.
    ///
    /// SCOPED TO WHAT A FIXTURE CAN PROVE. An Ability whose eligibility names
    /// `intent` or `workspaceFamily` anywhere in its tree is skipped (and said
    /// aloud, not silently) rather than failed: this context has no classifier
    /// behind it, so an eligibility miss there is not evidence of anything.
    /// After the routing fix, `coding` and `multimedia` express eligibility
    /// purely in `targetClass`/`utteranceToken`/`utterancePhrase` — exactly the
    /// kinds a fixture DOES carry — so both become fully checked here.
    @Test func everyRouteFixtureAdmitsTheAbilityOwningItsExpectedSkill() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)

        var checked = 0
        for package in packages {
            // NO PREDICATE MEANS ALWAYS ADMITTED — fully provable from a
            // fixture, unlike a predicate that names `intent`/`workspaceFamily`.
            // Only the latter is unprovable here; a nil eligibility is the
            // easiest case, not a reason to skip it.
            if let eligibility = package.ability.routing.eligibility,
               Self.dependsOnRuntimeClassifiedContext(eligibility) {
                print(
                    """
                    [routing-fixtures] SKIPPED (eligibility depends on a live \
                    classifier, not fixture data): \(package.package.id.rawValue)
                    """)
                continue
            }
            for fixture in package.fixtures where fixture.expectedDisposition == "route" {
                guard let expectedSkill = fixture.expectedSkill else { continue }
                guard package.skills.contains(where: { $0.id == expectedSkill }) else {
                    Issue.record(
                        """
                        \(package.package.id.rawValue) fixture \(fixture.id) names \
                        \(expectedSkill.rawValue), which is not one of its own Skills
                        """)
                    continue
                }
                let context = AbilityRoutingContext(
                    utterance: fixture.utterance,
                    targetClasses: fixture.targetClass.map { [$0] } ?? [],
                    interactions: Set(fixture.interactions))
                checked += 1
                #expect(
                    AbilityRoutingEvaluator.isEligible(package.ability.routing, in: context),
                    """
                    \(package.package.id.rawValue) fixture "\(fixture.utterance)" asserts \
                    routing to \(expectedSkill.rawValue), but the owning Ability's routing \
                    policy does not admit this context — the fixture's own claim is false.
                    """)
            }
        }
        #expect(checked > 0, "no shipped package/fixture combination was exercised")
    }
}
