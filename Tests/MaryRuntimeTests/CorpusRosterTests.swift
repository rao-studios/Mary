//
//  CorpusRosterTests.swift
//  MaryRuntimeTests
//
//  The crawl roster is the activated ability graph: expertise binds a live
//  app, a discipline may own the grammar, and neither half crawls alone.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryFoundationTestSupport
@testable import MaryPlugin
@testable import MaryRuntime
import MaryAmbient
import MaryTotem

@Suite struct CorpusRosterTests {

    @Test func aDisciplineAloneIsNotCrawled() {
        let discipline = PackageFixtures.minimalDiscipline
        let snapshot = snapshot(packages: [discipline])
        #expect(MaryRuntime.corpusRegistrations(from: snapshot).isEmpty)
    }

    @Test func expertiseWithoutCorpusInheritsDisciplineGrammar() {
        var discipline = PackageFixtures.minimalDiscipline
        discipline.corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift")
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = nil
        expertise.dependencies = [
            .init(packageID: discipline.package.id, minimumVersion: "1.0.0")
        ]
        let snapshot = snapshot(packages: [discipline, expertise])
        let registrations = MaryRuntime.corpusRegistrations(from: snapshot)
        #expect(registrations.count == 1)
        #expect(registrations[0].applicationID == "tests.editor")
        #expect(registrations[0].schema.notation == "swift")
        #expect(registrations[0].bundleIdentifiers == ["com.example.testeditor"])
    }

    @Test func expertiseCorpusWinsOverDisciplineGrammar() {
        var discipline = PackageFixtures.minimalDiscipline
        discipline.corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift")
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = PluginCorpusSchema(
            include: ["rtf"], notation: "prose")
        expertise.dependencies = [
            .init(packageID: discipline.package.id, minimumVersion: "1.0.0")
        ]
        let snapshot = snapshot(packages: [discipline, expertise])
        let registrations = MaryRuntime.corpusRegistrations(from: snapshot)
        #expect(registrations.map(\.schema.notation) == ["prose"])
    }

    @Test func leftoverApplicationAddressesClassifyAsAbility() {
        let group = TotemAddressClassifier.classifyGroup(id: "mary-application-deadbeef")
        #expect(group.lane == .ability)
        #expect(group.isLegacy)
        #expect(group.family == .legacyApplicationGroup)
        let live = TotemAddressClassifier.classifyGroup(id: "mary-ability-cafef00d")
        #expect(live.lane == .ability)
        #expect(!live.isLegacy)
        #expect(live.family == .abilityGroup)
    }

    @Test func durableExpertiseReceiptsIndexTheSignaledDiscipline() {
        let projection = ResolvedTotemProjection(
            id: "xcode.receipts",
            purpose: .receipt,
            persistence: .durable,
            includedFields: ["skillID"],
            excludedFields: [],
            redactContent: true,
            retentionSeconds: nil)
        let subject = DepositSubject(app: "xcode", projectIdentity: "/repos/Mary")
        let destinations = TotemContextStore.projectionDestinations(
            projection: projection,
            subject: subject,
            routingSubject: subject,
            applicationID: "xcode",
            targets: [
                AbilityTotemTarget(abilityID: "xcode", paradigm: .applicationExpertise),
                AbilityTotemTarget(abilityID: .coding, paradigm: .discipline),
            ],
            ownerID: "o")
        #expect(destinations.map(\.lane) == [.ability, .ability])
        let expected = [
            TotemMemoryTopology.abilityGroup(
                target: AbilityTotemTarget(abilityID: "xcode", paradigm: .applicationExpertise),
                ownerID: "o").id,
            TotemMemoryTopology.abilityGroup(
                target: AbilityTotemTarget(abilityID: .coding, paradigm: .discipline),
                ownerID: "o").id,
        ]
        #expect(destinations.map(\.id) == expected)
        #expect(!destinations.contains { $0.lane == .personal })
    }

    @Test func aSessionProjectionDoesNotMintAbilityGroups() {
        let projection = ResolvedTotemProjection(
            id: "window-management.receipts",
            purpose: .receipt,
            persistence: .session,
            includedFields: ["skillID"],
            excludedFields: [],
            redactContent: true,
            retentionSeconds: 3600)
        let subject = DepositSubject(app: "finder")
        let destinations = TotemContextStore.projectionDestinations(
            projection: projection,
            subject: subject,
            routingSubject: subject,
            applicationID: nil,
            targets: [
                AbilityTotemTarget(abilityID: "window-management", paradigm: .systemControl)
            ],
            ownerID: "o")
        #expect(destinations.isEmpty)
    }

    @Test func aUnitStampsTheDisciplineItPractices() {
        let unit = IndexedUnit(
            subject: DepositSubject(
                app: "xcode",
                documentIdentity: "Sources/Foo.swift",
                projectIdentity: "/repos/Mary"),
            projectName: "Mary",
            relativePath: "Sources/Foo.swift",
            contentHash: "abc",
            discipline: .coding)
        let composition = TotemContextStore.unitComposition(unit)
        let abilityEntity = composition.entities.first { $0.name == "coding" }
        #expect(abilityEntity?.kind == "ability")
        let practices = composition.relationships.first {
            $0.predicate == UnitRelationPredicate.practices.rawValue
        }
        #expect(practices?.subject == "Mary")
        #expect(practices?.object == "coding")
        let body = TotemContextStore.unitDocument(unit)
        #expect(body.contains("Discipline: coding"))
    }

    @Test func missingRequiredDisciplineDropsTheExpertiseCrawl() {
        var discipline = PackageFixtures.minimalDiscipline
        discipline.corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift")
        var expertise = PackageFixtures.applicationExpertise
        expertise.plugin?.corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift")
        expertise.dependencies = [
            .init(packageID: discipline.package.id, minimumVersion: "1.0.0")
        ]
        let snapshot = snapshot(packages: [expertise])
        #expect(MaryRuntime.corpusRegistrations(from: snapshot).isEmpty)
    }

    private func snapshot(packages: [MaryAbilityPackage]) -> AbilityRuntimeSnapshot {
        AbilityRuntimeSnapshot(
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
