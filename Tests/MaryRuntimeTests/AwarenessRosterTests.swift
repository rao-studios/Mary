//
//  AwarenessRosterTests.swift
//  MaryRuntimeTests
//
//  WHAT: Who gets followed — the applications that ASKED for awareness.
//  OUT:  MaryRuntime.awarenessRegistrations
//  PIN:  Sibling of CorpusRosterTests: one derivation from the activated
//        graph, and nothing here names an application.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryFoundationTestSupport
@testable import MaryPlugin
@testable import MaryRuntime

@Suite struct AwarenessRosterTests {

    /// THE WHOLE OPT-IN: an application declares the edge, and it is followed.
    /// `optional: true` is the shape `window-management` has always had — the
    /// application still loads when awareness is not installed — and it is
    /// still the application asking.
    @Test func anApplicationThatAskedForAwarenessIsFollowed() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.dependencies = [
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true)
        ]
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, expertise]))
        #expect(registrations.count == 1)
        #expect(registrations[0].applicationID == "tests.editor")
        #expect(registrations[0].bundleIdentifiers == ["com.example.testeditor"])
        #expect(registrations[0].displayName == "Test Editor")
        // The declaration says which channels exist; nothing is inferred.
        #expect(registrations[0].hasProseSurface)
        #expect(!registrations[0].hasCodeSurface)
    }

    /// A BROWSER IS FOLLOWED AS A PAGE, AND NEVER AS A PROJECT.
    ///
    /// PIN: THE CORPUS IS NIL BY RULE, NOT BY ACCIDENT. Awareness inherits a
    /// walk grammar from any discipline dependency that declares one, and a
    /// grammar pointed at the web would mean crawling it. `browsing.mary`
    /// declares none today; this pins that a future donor still cannot.
    @Test func aBrowserIsFollowedAsAPageWithNoCorpus() {
        var browser = PackageFixtures.applicationExpertise
        browser.dependencies = [
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true)
        ]
        browser.plugin?.webSurface = PackageFixtures.webSurface
        browser.plugin?.corpus = nil
        var discipline = Self.awarenessDiscipline
        // A donor that WOULD have handed a grammar over, if a page could take one.
        discipline.plugin?.corpus = nil
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [discipline, browser]))
        #expect(registrations.count == 1)
        #expect(registrations[0].hasWebSurface, "it shows pages")
        #expect(registrations[0].corpus == nil, "and the web is never a project")
    }

    /// A required edge is the same request, stated more strongly.
    @Test func aRequiredEdgeAsksJustAsLoudly() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.dependencies = [
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: false)
        ]
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, expertise]))
        #expect(registrations.map(\.applicationID) == ["tests.editor"])
    }

    /// SILENCE IS AN ANSWER. An application that never asked is not followed,
    /// however much of it Mary could read.
    @Test func anApplicationThatDidNotAskIsNotFollowed() {
        let expertise = PackageFixtures.applicationExpertise
        #expect(expertise.dependencies.isEmpty, "precondition: it asks for nothing")
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, expertise]))
        #expect(registrations.isEmpty)
    }

    /// The edge names a package that is not installed: nothing to inherit,
    /// nothing to follow. This is what an `optional: true` edge buys.
    @Test func anEdgeToAnAbsentDisciplineFollowsNothing() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.dependencies = [
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true)
        ]
        #expect(MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [expertise])).isEmpty)
    }

    /// A discipline alone is not an application, and is never followed.
    @Test func theDisciplineAloneIsNotFollowed() {
        #expect(MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline])).isEmpty)
    }

    /// THE CORPUS RIDES ALONG, and it is inherited the same way the crawl
    /// roster inherits it — an application that declares no grammar of its own
    /// walks its discipline's.
    @Test func theRegistrationInheritsTheDisciplineGrammar() {
        var craft = PackageFixtures.minimalDiscipline
        craft.corpus = PluginCorpusSchema(include: ["swift"], notation: "swift")
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = nil
        expertise.dependencies = [
            .init(packageID: craft.package.id, minimumVersion: "1.0.0"),
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true),
        ]
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, craft, expertise]))
        #expect(registrations.count == 1)
        #expect(registrations[0].corpus?.notation == "swift")
    }

    /// The application's own grammar wins over the one it could inherit.
    @Test func theApplicationsOwnGrammarWins() {
        var craft = PackageFixtures.minimalDiscipline
        craft.corpus = PluginCorpusSchema(include: ["swift"], notation: "swift")
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = PluginCorpusSchema(include: ["rtf"], notation: "prose")
        expertise.dependencies = [
            .init(packageID: craft.package.id, minimumVersion: "1.0.0"),
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true),
        ]
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, craft, expertise]))
        #expect(registrations.map(\.corpus?.notation) == ["prose"])
    }

    /// NO CORPUS IS A REAL STATE. An application can ask to be followed on a
    /// live surface without having a project on disk to trace through, and the
    /// honest answer to "who calls this" is then that there is nothing to walk.
    @Test func anApplicationWithNoGrammarIsStillFollowed() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = nil
        expertise.dependencies = [
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true)
        ]
        let registrations = MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, expertise]))
        #expect(registrations.count == 1)
        #expect(registrations[0].corpus == nil)
    }

    /// A missing REQUIRED discipline means the package is not really
    /// installed — `corpusRegistrations`' own gate, and the same answer here.
    @Test func missingRequiredDisciplineDropsTheRegistration() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.dependencies = [
            .init(packageID: "tests.minimal", minimumVersion: "1.0.0", optional: false),
            .init(packageID: "awareness", minimumVersion: "1.0.0", optional: true),
        ]
        #expect(MaryRuntime.awarenessRegistrations(
            from: snapshot(packages: [Self.awarenessDiscipline, expertise])).isEmpty)
    }

    // MARK: - Fixtures

    /// A discipline whose ability id IS `awareness` — the id the derivation
    /// asks for, stated by a package rather than by Swift.
    private static var awarenessDiscipline: MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: "awareness",
                version: "1.0.0",
                publisher: "Mary tests",
                summary: "Follows the work."),
            ability: .init(
                id: .awareness,
                title: "Awareness",
                summary: "Reads the unit in front of the user.",
                tint: "#5B8FA8",
                skills: [],
                paradigm: .discipline),
            skills: [])
    }

    private func snapshot(packages: [MaryAbilityPackage]) -> AbilityRuntime.Snapshot {
        AbilityRuntime.Snapshot(
            records: packages.map { package in
                AbilityPackageRecord(
                    package: package,
                    source: .sourceTree,
                    sourceURL: URL(fileURLWithPath: "/tmp/\(package.package.id.rawValue).mary"),
                    validation: .init(),
                    rawData: Data())
            },
            validation: .init(),
            adapterManifests: [])
    }
}
