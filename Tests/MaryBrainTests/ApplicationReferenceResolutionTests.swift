//
//  ApplicationReferenceResolutionTests.swift
//  MaryBrainTests
//
//  WHAT: The support graph read backwards, and which application a
//        system-control Skill was pointed at, against the SHIPPED packages.
//  OUT:  AbilityRuntime.Snapshot.applicationsSupporting / applicationCandidates
//        ApplicationReferenceResolution.resolve
//  PIN:  OPTIONAL EDGES ONLY HERE — the mirror image of
//        `ExpertiseDependentsTests`, which proves the same edges stay OUT of
//        the expertise index. Both must hold at once or one of the two indexes
//        has quietly become the other.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct ApplicationReferenceResolutionTests {

    /// Every application package that names `window-management` as an optional
    /// support, plus the host itself and the disciplines they require — a
    /// package whose required dependency is absent still loads, but the graph
    /// reads more honestly with them present.
    private static let names = [
        "window-management", "writing", "browsing",
        "textedit", "pages", "safari", "chrome",
    ]

    private func shippedSnapshot() throws -> AbilityRuntime.Snapshot? {
        guard let abilities = InstalledPackages.installed() else { return nil }
        let packages = try Self.names.map { name -> MaryAbilityPackage in
            try AbilityPackageCodec.load(
                from: abilities.appendingPathComponent("\(name).mary"))
        }
        let plugins = PluginCompiler.compile(
            packages: packages, nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        return AbilityRuntime.Snapshot(
            records: zip(packages, Self.names).map { package, name in
                AbilityPackageRecord(
                    package: package, source: .sourceTree,
                    sourceURL: abilities.appendingPathComponent("\(name).mary"),
                    validation: .init(), rawData: Data())
            },
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            plugins: plugins)
    }

    // MARK: - The index

    /// THE EDGE THAT WAS BEING THROWN AWAY. Every application package already
    /// declares `window-management, optional`; nothing read it until now.
    @Test func applicationsDeclareTheirWindowHost() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let supported = Set(snapshot.applicationsSupporting(
            AbilityID("window-management")))
        #expect(supported.contains(AbilityID("textedit")))
        #expect(supported.contains(AbilityID("safari")))
        #expect(supported.contains(AbilityID("chrome")))
        #expect(supported.contains(AbilityID("pages")))
    }

    /// A DISCIPLINE IS NOT AN APPLICATION. `writing` and `browsing` also depend
    /// on `window-management`, and they carry no application affinity — so they
    /// are not candidates for "which app did they mean".
    @Test func disciplinesAreNotCandidates() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let supported = Set(snapshot.applicationsSupporting(
            AbilityID("window-management")))
        #expect(!supported.contains(AbilityID("writing")))
        #expect(!supported.contains(AbilityID("browsing")))
    }

    /// The mirror of `ExpertiseDependentsTests.anOptionalDependencyIsNotInherited`:
    /// reading the optional edges here must not have widened the index there.
    @Test func theExpertiseIndexIsUnchanged() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        #expect(snapshot.expertiseAbilities(
            extending: AbilityID("window-management")).isEmpty)
        // …while the required discipline edges still resolve.
        #expect(snapshot.expertiseAbilities(extending: AbilityID("writing"))
            .contains(AbilityID("textedit")))
    }

    /// OPT-IN, NEVER AMBIENT. `bring-all-windows-forward` names no application
    /// and must not be handed one, even though its Ability has candidates.
    @Test func onlyADeclaringSkillGetsCandidates() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let opener = try #require(
            snapshot.skill(id: SkillID("window-management.open-new-window")))
        let raiser = try #require(
            snapshot.skill(id: SkillID("window-management.bring-all-windows-forward")))
        #expect(!snapshot.applicationCandidates(for: opener).isEmpty)
        #expect(snapshot.applicationCandidates(for: raiser).isEmpty)
    }

    // MARK: - The resolution

    /// THE REPORTED CASE. "Open a new textedit window" resolves to TextEdit
    /// with nobody having hardcoded the name anywhere — the package's own
    /// alias is what the sentence reached.
    @Test func namingTheApplicationResolvesIt() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("window-management.open-new-window")))
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new textedit window.",
            assertedApplicationIDs: ["textedit"]))
        #expect(verdict.hostID == AbilityID("window-management"))
        #expect(verdict.chosen?.applicationID == "textedit")
        #expect(verdict.chosen?.standing == .named)
    }

    /// TWO NAMED IS AN AMBIGUITY IN THE SENTENCE, and inventing an answer for
    /// it is worse than falling to the model, which can ask.
    @Test func twoNamedApplicationsResolveToNothing() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("window-management.open-new-window")))
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new safari and chrome window.",
            assertedApplicationIDs: ["safari", "chrome"]))
        #expect(verdict.chosen == nil)
    }

    /// A WORD THE HOST OWNS CANNOT NAME AN APPLICATION. "window" is
    /// `window-management`'s own token; on its own it names no application.
    @Test func theHostsOwnVocabularyNamesNoApplication() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("window-management.open-new-window")))
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new window."))
        #expect(verdict.chosen == nil)
    }

    /// A Skill that never declared `resolvesApplication` has no question to
    /// answer, so the resolver abstains outright rather than returning a tier.
    @Test func aNonDeclaringSkillGetsNoVerdict() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("window-management.bring-all-windows-forward")))
        #expect(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Bring all my windows forward.") == nil)
    }

    /// The candidate tier is drawn even when nothing is chosen — a bench that
    /// could only say "no match" could not tell 0.61 from 0.20.
    @Test func everyCandidateIsReportedEvenWithoutAWinner() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("window-management.open-new-window")))
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot, utterance: "Open a new window."))
        #expect(verdict.candidates.count
            == snapshot.applicationCandidates(for: skill).count)
    }
}
