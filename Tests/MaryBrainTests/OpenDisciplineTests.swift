//
//  OpenDisciplineTests.swift
//  MaryBrainTests
//
//  WHAT: The discipline axis is OPEN — a craft nobody compiled in is
//        identified from language, leads a turn, and prints its own name.
//  PIN:  THIS SUITE IS THE CLAIM. Coding and writing passing proves nothing
//        about openness: they are the two that used to be enum cases. Every
//        test here uses a discipline that exists only in a synthetic package,
//        so it can only pass if the axis really is whatever is installed.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct OpenDisciplineTests {

    /// A discipline Mary was never built with. If any of these pass, no list
    /// in the codebase decides what a craft is.
    private static let sketching = AbilityID("sketching")

    // MARK: - Identified from language

    /// THE HEADLINE. A package declares a craft and seeds its triggers; the
    /// words then route to it with nothing in Swift ever naming "sketching".
    @Test func aDisciplineNobodyCompiledInIsIdentifiedFromTheWords() throws {
        let registry = try #require(Self.registry(), "fixture failed to build")

        let verdict = registry.discipline(in: "sketch the layout")
        #expect(verdict == WorkspaceFocus(Self.sketching))
        #expect(verdict?.rawValue == "sketching")
    }

    /// The registry answers WHICH crafts exist — the question that used to be
    /// a two-case enum.
    @Test func theDisciplineRosterComesFromTheInstalledGraph() throws {
        let registry = try #require(Self.registry(), "fixture failed to build")

        #expect(registry.disciplines.contains(Self.sketching))
        #expect(!registry.disciplines.contains(AbilityID("some-expertise")),
                "an applicationExpertise package is not a craft")
    }

    /// CONTESTED STAYS UNDECIDED. Two crafts named equally is the open-set
    /// spelling of the old "cues from both sides cancel to nil" rule: a turn
    /// that names two disciplines defers to window truth rather than guessing.
    @Test func aContestedUtteranceNamesNoDiscipline() throws {
        let registry = try #require(Self.registry(), "fixture failed to build")

        #expect(registry.discipline(in: "tied phrase") == nil)
    }

    /// Words that name no craft at all leave the axis alone.
    @Test func anUnrelatedUtteranceNamesNoDiscipline() throws {
        let registry = try #require(Self.registry(), "fixture failed to build")

        #expect(registry.discipline(in: "xyzzy plugh") == nil)
    }

    /// WITHOUT A VECTORIZER THERE IS NO CUE. The old word lists worked with no
    /// model at all; this abstains instead, which is the P3 trade stated out
    /// loud rather than discovered later.
    @Test func withNoIndexTheAxisAbstains() {
        #expect(AbilityRuntime.Snapshot.empty.discipline(in: "sketch the layout") == nil)
        #expect(AbilityRuntime.Snapshot.empty.disciplines.isEmpty)
    }

    // MARK: - It leads, and it prints

    /// A third craft must be able to LEAD, or the set is open for
    /// identification and closed for everything that matters.
    @Test func athirdDisciplineCanLeadTheTurn() {
        let sketching = WorkspaceFocus(Self.sketching)
        let lead = WorkspaceFocusArbiter.lead(
            focus: sketching,
            live: [.coding, sketching])
        #expect(lead == sketching)
    }

    /// Asked-for-and-absent still falls back through registry order, and the
    /// staleness gate still bounds the fallback rather than the ask.
    @Test func theFallbackRespectsOrderAndFreshness() {
        let sketching = WorkspaceFocus(Self.sketching)
        #expect(
            WorkspaceFocusArbiter.lead(focus: sketching, live: [.coding]) == .coding,
            "absent ask falls back to what is live")
        #expect(
            WorkspaceFocusArbiter.lead(
                focus: sketching, live: [.coding], strictFocus: true) == nil,
            "strict would rather lead nothing than a craft nobody named")
        #expect(
            WorkspaceFocusArbiter.lead(
                focus: nil, live: [.coding, sketching], inPlay: [sketching]) == sketching,
            "a stale craft does not inherit the lead unasked")
    }

    /// Display surfaces print whatever craft it is, rather than mapping two
    /// known names and dropping the rest.
    @Test func aThirdDisciplinePrintsItsOwnName() {
        #expect(AmbientCaptureBuilder.token(for: WorkspaceFocus(Self.sketching)) == "sketching")
    }

    // MARK: - Fixture

    /// A synthetic graph: one discipline package that seeds "sketch the
    /// layout", one expertise package that must NOT count as a craft, and a
    /// second discipline sharing a phrase so the tie can be tested.
    private static func registry() -> AbilityRuntime.Snapshot? {
        func record(
            _ id: String,
            paradigm: AbilityParadigm,
            tokens: [String]
        ) -> AbilityPackageRecord {
            let package = MaryAbilityPackage(
                package: .init(
                    id: PackageID("tests.\(id)"),
                    version: "1.0.0",
                    publisher: "tests",
                    summary: "Open-axis fixture."),
                ability: .init(
                    id: AbilityID(id),
                    title: id,
                    summary: "Fixture ability.",
                    tint: "#112233",
                    triggers: AbilityTriggerSchema(tokens: tokens),
                    skills: [],
                    paradigm: paradigm),
                skills: [])
            return AbilityPackageRecord(
                package: package,
                source: .sourceTree,
                sourceURL: URL(fileURLWithPath: "/tmp/\(id).mary"),
                validation: .init(),
                rawData: Data())
        }
        let records = [
            record("sketching", paradigm: .discipline,
                   tokens: ["sketch the layout", "tied phrase"]),
            record("modelling", paradigm: .discipline,
                   tokens: ["extrude the mesh", "tied phrase"]),
            record("some-expertise", paradigm: .applicationExpertise,
                   tokens: ["open the inspector"]),
        ]
        // Each phrase is its own basis vector, EXCEPT the tied phrase, which
        // both disciplines seed — so it scores identically for both and the
        // margin rule must refuse it.
        let vectorizer = PhraseVectorizer(phrases: [
            "sketch the layout", "extrude the mesh", "tied phrase",
            "open the inspector",
        ])
        guard let index = SemanticAbilityRequestIndex.build(
            records: records, vectorizer: vectorizer)
        else { return nil }
        return AbilityRuntime.Snapshot(
            records: records,
            validation: .init(),
            adapterManifests: [],
            semanticIndex: index)
    }

    /// One orthogonal basis vector per listed phrase; anything else is nil, so
    /// a miss is a miss rather than a stale neighbour.
    private struct PhraseVectorizer: AmbientTextVectorizer {
        let phrases: [String]

        func vector(for text: String) -> [Float]? {
            let first = text.split(
                omittingEmptySubsequences: true, whereSeparator: \.isNewline
            ).first.map(String.init) ?? text
            let folded = first.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = phrases.firstIndex(of: folded) else { return nil }
            var vector = [Float](repeating: 0, count: phrases.count)
            vector[index] = 1
            return vector
        }
    }
}
