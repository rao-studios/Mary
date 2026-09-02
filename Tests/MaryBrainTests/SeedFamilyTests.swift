//
//  SeedFamilyTests.swift
//  MaryBrainTests
//
//  WHAT: The `transform` family — corpus hygiene, and the offer road it gates.
//  PIN:  THE OFFER ROAD HAD NO TESTS AT ALL before this. `OfferedProse.offer`
//        and `bareAcceptance` rung 6 both turn on "did Mary offer a
//        transformation?", and a false positive there WRITES — so the seam
//        that answers it is pinned here on both sides.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct SeedFamilyTests {

    // MARK: - Corpus hygiene, against what actually ships

    /// Every family a package authors must be one the Brain reads. An unread
    /// key is dead corpus: authored, shipped, and consulted by nothing.
    @Test func shippedFamiliesAreAllKnown() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        var unknown: [String] = []
        var counts: [String: Int] = [:]
        for url in try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "mary" }) {
            let package = try AbilityPackageCodec.load(from: url)
            for (family, seeds) in package.ability.triggers.seedFamilies {
                if !SemanticSeedFamilyIndex.knownFamilies.contains(family) {
                    unknown.append("\(package.ability.id.rawValue): \(family)")
                }
                counts[family, default: 0] += seeds.count
                #expect(!seeds.isEmpty, "\(family) is declared empty")
                for seed in seeds {
                    #expect(
                        seed.split(whereSeparator: \.isWhitespace).count >= 2,
                        "[\(seed)] is a word, not a sentence — this corpus is embedded")
                }
            }
        }
        #expect(unknown.isEmpty, "unread families: \(unknown)")
        #expect(
            (counts[SemanticSeedFamilyIndex.transform] ?? 0) >= 8,
            "the transform family replaced forty verbs; it needs real breadth")
    }

    // MARK: - What the family answers

    /// BOTH SIDES, ONE FAMILY: the user asking for a change and Mary offering
    /// one score alike. The question mark is what makes the second an offer,
    /// and that is the caller's test, not the corpus's.
    @Test func theFamilyRecognizesAsksAndOffersAlike() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        #expect(index.matches(SemanticSeedFamilyIndex.transform, in: "tighten this up"))
        #expect(index.matches(SemanticSeedFamilyIndex.transform, in: "Want me to tighten it up?"))
        #expect(!index.matches(SemanticSeedFamilyIndex.transform, in: "what time is it"))
    }

    /// NIL IS NOT ZERO. A caller must be able to tell "scored badly" from
    /// "could not be scored at all".
    @Test func anUnknownFamilyScoresNilRatherThanZero() throws {
        let index = try #require(Self.index(), "fixture failed to build")

        #expect(index.bestScore("no-such-family", in: "tighten this up") == nil)
        #expect(index.bestScore(SemanticSeedFamilyIndex.transform, in: "tighten this up") != nil)
    }

    // MARK: - The offer road

    /// AN OFFER IS A QUESTION THAT NAMES A TRANSFORMATION, and it must carry
    /// exactly one framed draft. This is the road `acceptedProse` walks before
    /// it types anything, and it had no coverage until now.
    @Test func aFramedOfferIsRecognizedAndABareQuestionIsNot() throws {
        let registry = try #require(Self.registry(), "fixture failed to build")

        try AmbientCapabilityIndexProvider.$scoped.withValue(registry) {
            let draft = "The harbour lights came up one by one across the water"
            let offered = OfferedProse.offer(
                in: "Want me to tighten it up, something like \"\(draft)\"?")
            #expect(offered == draft)

            // A question that names a transformation but offers no draft.
            #expect(OfferedProse.offer(in: "Want me to tighten it up?") == nil)
            // A STATEMENT carrying a draft is not an offer — the reply must
            // END in a question, or she is reporting rather than proposing.
            #expect(OfferedProse.offer(
                in: "I tightened it up, something like \"\(draft)\".") == nil)
            // A question that names no transformation at all.
            #expect(OfferedProse.offer(
                in: "What time is it, something like \"\(draft)\"?") == nil)
        }
    }

    /// WITHOUT A VECTORIZER THE OFFER ROAD CLOSES — it does not fall open.
    /// A write path that guessed when it could not score would be the worst
    /// possible failure here.
    @Test func withNoIndexNothingIsAnOffer() {
        let draft = "The harbour lights came up one by one across the water"
        try? AmbientCapabilityIndexProvider.$scoped.withValue(
            AbilityRuntimeSnapshot.empty
        ) {
            #expect(OfferedProse.offer(
                in: "Want me to tighten it up, something like \"\(draft)\"?") == nil)
        }
    }

    // MARK: - Fixture

    private static func index() -> SemanticSeedFamilyIndex? {
        SemanticSeedFamilyIndex.build(
            records: [Self.record()], vectorizer: Self.vectorizer)
    }

    private static func registry() -> AbilityRuntimeSnapshot? {
        guard let index = index() else { return nil }
        return AbilityRuntimeSnapshot(
            records: [Self.record()],
            validation: .init(),
            adapterManifests: [],
            semanticSeedFamilyIndex: index)
    }

    private static let asks = ["tighten this up", "want me to tighten it up"]

    private static func record() -> AbilityPackageRecord {
        let package = MaryAbilityPackage(
            package: .init(
                id: PackageID("tests.seed-family"),
                version: "1.0.0",
                publisher: "tests",
                summary: "Seed family fixture."),
            ability: .init(
                id: AbilityID("fixture-writing"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                triggers: AbilityTriggerSchema(
                    seedFamilies: [SemanticSeedFamilyIndex.transform: asks]),
                skills: []),
            skills: [])
        return AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/seed-family.mary"),
            validation: .init(),
            rawData: Data())
    }

    /// Every seeded sentence shares one basis vector; anything else is nil.
    /// The fake asserts the SEAM, never the OS model's judgement.
    private static let vectorizer = FamilyVectorizer(members: asks)

    private struct FamilyVectorizer: AmbientTextVectorizer {
        let members: [String]

        func vector(for text: String) -> [Float]? {
            let first = text.split(
                omittingEmptySubsequences: true, whereSeparator: \.isNewline
            ).first.map(String.init) ?? text
            let folded = first.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // A seeded sentence, or a reply that contains one, is in the family.
            guard members.contains(where: folded.contains) else { return nil }
            return [1, 0]
        }
    }
}
