//
//  CorpusRosterTests.swift
//  MaryRuntimeTests
//
//  WHAT: Crawl roster is the activated ability graph — expertise plus discipline.
//  OUT:  CorpusRoster
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryFoundationTestSupport
@testable import MaryPlugin
@testable import MaryRuntime
import MaryAmbient
import MaryThread

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

    @Test func leftoverApplicationAddressesAreUnknown() {
        let group = ThreadAddressClassifier.classifyGroup(id: "mary-application-deadbeef")
        #expect(group.family == .unknown)
        #expect(group.lane == nil)
        let live = ThreadAddressClassifier.classifyGroup(id: "mary-ability-cafef00d")
        #expect(live.lane == .ability)
        #expect(live.family == .abilityGroup)
    }

    @Test func leftoverContextAddressesAreUnknown() {
        let group = ThreadAddressClassifier.classifyGroup(id: "mary-context-owner-abc")
        #expect(group.family == .unknown)
        #expect(group.lane == nil)
        let document = ThreadAddressClassifier.classifyDocument(id: "mary-context-owner-abc")
        #expect(document.family == .unknown)
    }

    @Test func destinationWithoutAScopeDoesNotMintAContextPool() {
        #expect(ThreadContextStore.destination(subject: .unfocused, ownerID: "o") == nil)
        let focused = DepositSubject(app: "xcode", projectIdentity: "/repos/Mary")
        let dest = ThreadContextStore.destination(subject: focused, ownerID: "o")
        #expect(dest?.id.hasPrefix("mary-scope-") == true)
        #expect(dest?.id.hasPrefix("mary-context-") != true)
    }

    @Test func styleFilesToTheStyleGroup() {
        let group = ThreadMemoryTopology.styleGroup(ownerID: "o")
        #expect(group.id == "mary-style-o")
        #expect(group.label == "Style")
        let classified = ThreadAddressClassifier.classifyGroup(id: group.id)
        #expect(classified.family == .styleGroup)
        #expect(classified.lane == .personal)
        let profile = ThreadMemoryTopology.styleProfileDocumentID(
            subject: "writing", ownerID: "o")
        #expect(profile.hasPrefix("mary-style-profile-"))
        #expect(ThreadAddressClassifier.classifyDocument(id: profile).family == .styleProfile)
    }

    @Test func behaviorFamiliesPreferTheLongerPrefix() {
        let interactionGroup = ThreadMemoryTopology.interactionGroup(ownerID: "o")
        #expect(ThreadAddressClassifier.classifyGroup(id: interactionGroup.id).family
                == .behaviorInteraction)
        let episodeID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let episodeDoc = ThreadMemoryTopology.behaviorDocumentID(episodeID: episodeID)
        let interactionDoc = ThreadMemoryTopology.interactionDocumentID(episodeID: episodeID)
        #expect(ThreadAddressClassifier.classifyDocument(id: episodeDoc).family
                == .behaviorEpisode)
        #expect(ThreadAddressClassifier.classifyDocument(id: episodeDoc).lane == .ability)
        #expect(ThreadAddressClassifier.classifyDocument(id: interactionDoc).family
                == .behaviorInteractionDocument)
        #expect(ThreadAddressClassifier.classifyDocument(id: interactionDoc).lane == .personal)
    }

    @Test func durableExpertiseReceiptsIndexTheSignaledDiscipline() {
        let projection = ResolvedThreadProjection(
            id: "xcode.receipts",
            purpose: .receipt,
            persistence: .durable,
            includedFields: ["skillID"],
            excludedFields: [],
            redactContent: true,
            retentionSeconds: nil)
        let subject = DepositSubject(app: "xcode", projectIdentity: "/repos/Mary")
        let destinations = ThreadContextStore.projectionDestinations(
            projection: projection,
            subject: subject,
            routingSubject: subject,
            applicationID: "xcode",
            targets: [
                AbilityThreadTarget(abilityID: "xcode", paradigm: .applicationExpertise),
                AbilityThreadTarget(abilityID: .coding, paradigm: .discipline),
            ],
            ownerID: "o")
        #expect(destinations.map(\.lane) == [.ability, .ability])
        let expected = [
            ThreadMemoryTopology.abilityGroup(
                target: AbilityThreadTarget(abilityID: "xcode", paradigm: .applicationExpertise),
                ownerID: "o").id,
            ThreadMemoryTopology.abilityGroup(
                target: AbilityThreadTarget(abilityID: .coding, paradigm: .discipline),
                ownerID: "o").id,
        ]
        #expect(destinations.map(\.id) == expected)
        #expect(!destinations.contains { $0.lane == .personal })
    }

    @Test func aSessionProjectionDoesNotMintAbilityGroups() {
        let projection = ResolvedThreadProjection(
            id: "window-management.receipts",
            purpose: .receipt,
            persistence: .session,
            includedFields: ["skillID"],
            excludedFields: [],
            redactContent: true,
            retentionSeconds: 3600)
        let subject = DepositSubject(app: "finder")
        let destinations = ThreadContextStore.projectionDestinations(
            projection: projection,
            subject: subject,
            routingSubject: subject,
            applicationID: nil,
            targets: [
                AbilityThreadTarget(abilityID: "window-management", paradigm: .systemControl)
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
        let composition = ThreadContextStore.unitComposition(unit)
        let abilityEntity = composition.entities.first { $0.name == "coding" }
        #expect(abilityEntity?.kind == "ability")
        let practices = composition.relationships.first {
            $0.predicate == UnitRelationPredicate.practices.rawValue
        }
        #expect(practices?.subject == "Mary")
        #expect(practices?.object == "coding")
        let body = ThreadContextStore.unitDocument(unit)
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
