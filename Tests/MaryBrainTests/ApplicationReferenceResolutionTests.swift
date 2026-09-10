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

    // MARK: - One set, read by both halves of the pragma

    /// THE ASYMMETRY THAT MADE `{application}` HALF A FEATURE.
    ///
    /// Expansion took BOTH backwards edges; resolution took only the support
    /// one. So `writing` — a discipline, reached by the REQUIRED edge from its
    /// editors — expanded over three of them and resolved over none. A Skill of
    /// its could declare `resolvesApplication`, pass the validator, and be
    /// handed an empty candidate set on every single turn.
    @Test func aDisciplineSkillCanBePointedAtItsEditors() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let typer = try #require(
            snapshot.skill(id: SkillID("writing.type-at-cursor")))
        let candidates = Set(snapshot.applicationCandidates(for: typer))
        #expect(candidates.contains(AbilityID("textedit")))
        #expect(candidates.contains(AbilityID("pages")))
        // The host itself is not one of its own candidates.
        #expect(!candidates.contains(AbilityID("writing")))
    }

    /// THE TWO HALVES NOW AGREE BY CONSTRUCTION, and this is what says so: the
    /// set a Skill resolves over is exactly the set `{application}` expands to
    /// for its Ability. They were allowed to differ, and did.
    @Test func candidatesAreExactlyWhatTheSlotExpandsTo() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        for id in ["writing.type-at-cursor", "window-management.open-new-window"] {
            let skill = try #require(snapshot.skill(id: SkillID(id)))
            let resolved = snapshot.applicationCandidates(for: skill)
                .compactMap { snapshot.applicationID(ofAbility: $0) }
            let expanded = snapshot
                .pointableApplications(of: skill.ability.id).map(\.id)
            #expect(resolved == expanded, "\(id) resolves over a different set than it expands over")
        }
    }

    /// WIDENING THE SET MUST NOT HAVE MOVED THE ONE CASE THAT ALREADY WORKED.
    /// `window-management` is `.systemControl`, and `buildExpertiseIndex` admits
    /// only `.discipline` dependencies — so its expertise half is empty and the
    /// union is the support edge it always was.
    @Test func theSystemControlHostIsUnchangedByTheUnion() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let host = AbilityID("window-management")
        #expect(snapshot.pointableAbilities(of: host)
            == snapshot.applicationsSupporting(host))
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

    // MARK: - A staged surface is an assertion

    /// THE DEFAULT THAT OUTRANKED A FACT.
    ///
    /// `type_at_cursor` documents "omit `app` to type into the just-opened
    /// document". It could not once be honoured: an omitted `app` on a
    /// discipline's Skill reaches `ExpertiseResolution`, which always chooses
    /// while the discipline has any dependent — so the omission came back
    /// filled with whichever editor declared the highest preference, at
    /// standing `staticPreference`. The typer resolves a NAMED application
    /// before it looks at the stage, so a window Mary had just opened and
    /// proved lost to a number in a package.
    @Test func aColdRosterStillAnswersWithADeclaredPreference() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let typer = try #require(
            snapshot.skill(id: SkillID("writing.type-at-cursor")))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: typer, snapshot: snapshot,
            utterance: "write a poem in it",
            ledger: ApplicationHabitLedger()))
        // The fact under test: it answers, and only from declared preference.
        #expect(verdict.chosen?.standing == .staticPreference)
    }

    /// AND THE FACT NOW WINS. The staged surface is asserted at dispatch, so
    /// the same cold roster resolves the window that was actually opened.
    @Test func aStagedSurfaceBeatsTheDeclaredPreference() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let typer = try #require(
            snapshot.skill(id: SkillID("writing.type-at-cursor")))
        let staged = try #require(
            snapshot.applicationID(forBundleIdentifier: "com.apple.TextEdit"))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: typer, snapshot: snapshot,
            assertedApplicationIDs: [staged],
            utterance: "write a poem in it",
            ledger: ApplicationHabitLedger()))
        #expect(verdict.chosen?.applicationID == "textedit")
        #expect(verdict.chosen?.standing == .asserted)
    }

    /// A STAGED EDITOR CANNOT SPEAK FOR A MUSIC TURN. An asserted id outside
    /// the discipline's own candidates is ignored, which is what keeps the
    /// staging read at dispatch from leaking across disciplines.
    @Test func theBundleJoinIsBoundedByThePackages() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        #expect(snapshot.applicationID(
            forBundleIdentifier: "com.apple.TextEdit") == "textedit")
        // Case-insensitive, because a bundle id observed off a process is not
        // guaranteed to match the package's spelling.
        #expect(snapshot.applicationID(
            forBundleIdentifier: "COM.APPLE.TEXTEDIT") == "textedit")
        #expect(snapshot.applicationID(forBundleIdentifier: "") == nil)
        #expect(snapshot.applicationID(
            forBundleIdentifier: "com.example.nothing") == nil)
    }
}
