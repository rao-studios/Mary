//
//  DominanceMarginTests.swift
//  MaryBrainTests
//
//  WHAT: Recall keeps the leader and its near neighbours, not everything that
//        clears the floor.
//  PIN:  The orthogonal cluster fakes elsewhere cannot express a GRADED gap,
//        which is the whole subject here — so this file builds vectors by hand.
//        That is test scaffolding for arithmetic, not a matcher.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct DominanceMarginTests {

    /// A floor alone says "this could be about an application"; only the gap
    /// says WHICH. Measured against the real model, half the installed
    /// expertise cleared 0.62 together on an app-shaped sentence.
    @Test func onlyTheLeaderAndItsNearNeighboursAreRecalled() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        let recalled = index.requestedAbilities(in: "probe").map(\.rawValue).sorted()
        #expect(recalled == ["leader", "sibling"],
                "the straggler cleared the floor but trails the leader by more than the margin")
    }

    /// Everything below the floor is still cut, margin or no margin.
    @Test func theFloorStillApplies() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        let scored = index.affinities(in: "probe")
        #expect((scored[AbilityID("bystander")] ?? 0) > 0,
                "it scores — it is simply below the floor")
        #expect(!index.requestedAbilities(in: "probe").contains(AbilityID("bystander")))
    }

    /// THE RAW MAP STAYS RAW. `discipline(in:)` applies its own floor and
    /// margin over `affinities`; if the dominance rule leaked into there, the
    /// craft axis would be narrowed twice by two different constants.
    @Test func affinitiesAreNotNarrowedByDominance() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        let scored = index.affinities(in: "probe")
        #expect(scored.count == 4,
                "every scored ability, floor and margin alike unapplied: \(scored)")
    }

    /// A single survivor is unaffected — the leader always leads itself.
    @Test func aLoneLeaderIsKept() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        #expect(index.requestedAbilities(in: "solo") == [AbilityID("leader")])
    }

    // MARK: - Fixture

    /// Three abilities at hand-set distances from one query: leader 0.80,
    /// sibling 0.78 (inside the 0.05 margin), straggler 0.65 (clears the 0.62
    /// floor, trails by 0.15). Plus a bystander below the floor.
    private static func index() -> SemanticAbilityRequestIndex? {
        func record(_ id: String, token: String, extra: String? = nil) -> AbilityPackageRecord {
            let package = MaryAbilityPackage(
                package: .init(
                    id: PackageID("tests.\(id)"), version: "1.0.0",
                    publisher: "tests", summary: "Dominance fixture."),
                ability: .init(
                    id: AbilityID(id), title: id, summary: "Fixture ability.",
                    tint: "#112233",
                    triggers: AbilityTriggerSchema(tokens: [token] + (extra.map { [$0] } ?? [])),
                    skills: []),
                skills: [])
            return AbilityPackageRecord(
                package: package, source: .sourceTree,
                sourceURL: URL(fileURLWithPath: "/tmp/\(id).mary"),
                validation: .init(), rawData: Data())
        }
        let records = [
            record("leader", token: "leader-term", extra: "solo-term"),
            record("sibling", token: "sibling-term"),
            record("straggler", token: "straggler-term"),
            record("bystander", token: "bystander-term"),
        ]
        return SemanticAbilityRequestIndex.build(
            records: records, vectorizer: GradedVectorizer())
    }

    /// Unit vectors placed so the cosine with a query is a CHOSEN number.
    /// Axis 0 is the "probe" query, axis 1 is the "solo" query; a term's
    /// component on an axis is exactly its similarity to that query, and the
    /// remainder goes on axis 2 to keep the vector unit-length.
    private struct GradedVectorizer: AmbientTextVectorizer {
        /// (similarity to "probe", similarity to "solo")
        private static let scores: [String: (Float, Float)] = [
            "leader-term": (0.80, 0.00),
            "sibling-term": (0.78, 0.00),
            "straggler-term": (0.65, 0.00),
            "bystander-term": (0.40, 0.00),
            // The leader's second term: only "solo" resembles it, so that
            // query leaves exactly one ability above the floor.
            "solo-term": (0.00, 0.90),
        ]

        func vector(for text: String) -> [Float]? {
            if text == "probe" { return [1, 0, 0] }
            if text == "solo" { return [0, 1, 0] }
            guard let (probe, solo) = Self.scores[text] else { return nil }
            let rest = max(0, 1 - probe * probe - solo * solo)
            return [probe, solo, sqrt(rest)]
        }
    }
}
