//
//  AbilityTotemTopologyTests.swift
//  MaryBrainTests
//
//  Ability Totem groups are keyed by ability and paradigm. Seer chat is
//  Personal interactions plus Seer's own memory; Ability codec stays off
//  that request.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct AbilityTotemTopologyTests {

    private let coding = AbilityTotemTarget(abilityID: .coding, paradigm: .discipline)
    private let xcode = AbilityTotemTarget(
        abilityID: "xcode", paradigm: .applicationExpertise)

    @Test func abilityGroupsAreStableAndDistinct() {
        let a = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o")
        let b = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o")
        let otherOwner = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "p")
        let expertise = TotemMemoryTopology.abilityGroup(target: xcode, ownerID: "o")
        #expect(a.id == b.id)
        #expect(a.id.hasPrefix("mary-ability-"))
        #expect(a.label.hasPrefix("Ability —"))
        #expect(a.id != otherOwner.id)
        #expect(a.id != expertise.id)
    }

    @Test func seerPersonalScopeNeverOpensAbilityGroups() {
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let scope = TotemMemoryTopology.seerPersonalScope(
            subject: subject, ownerID: "o")
        #expect(scope.groups.map(\.id) == [
            "mary-behavior-interaction-o", "memory-o", "resonance-o",
        ])
        #expect(scope.aggregate == false)
        #expect(scope.groups.allSatisfy { !$0.id.hasPrefix("mary-ability-") })
        #expect(!scope.groups.contains { $0.id.hasPrefix("mary-scope-") })
        #expect(!scope.groups.contains { $0.id.hasPrefix("mary-context-") })
    }

    @Test func maryAbilityScopeIsTheAbilityGroup() {
        let plan = TotemMemoryPlan(
            lanes: [.ability],
            abilityTargets: [coding],
            expandDisciplineUsage: true)
        let scope = TotemMemoryTopology.maryAbilityScope(for: plan, ownerID: "o")
        let expected = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o")
        #expect(scope.groups.map(\.id) == [expected.id])
        #expect(scope.relationshipHints.contains("practices"))
        #expect(scope.relationshipHints.contains("coding"))
        #expect(!scope.groups.contains { $0.id.hasPrefix("mary-scope-") })
        #expect(scope.aggregate == false)
    }

    @Test func mixedPlanStillSplitsByTransport() {
        let plan = TotemMemoryPlan(
            lanes: [.ability, .personal],
            abilityTargets: [coding],
            expandDisciplineUsage: true)
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let seer = TotemMemoryTopology.seerPersonalScope(
            subject: subject, ownerID: "o")
        let ability = TotemMemoryTopology.maryAbilityScope(for: plan, ownerID: "o")
        let abilityID = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o").id
        #expect(seer.groups.allSatisfy { !$0.id.hasPrefix("mary-ability-") })
        #expect(ability.groups.map(\.id) == [abilityID])
        #expect(seer.groups.contains { $0.id == "mary-behavior-interaction-o" })
        #expect(!seer.groups.contains { $0.id.hasPrefix("mary-scope-") })
        #expect(!seer.groups.contains { $0.id.hasPrefix("mary-context-") })
    }

    @Test func seerRetrievalScopeIgnoresAbilityTargets() {
        let plan = TotemMemoryPlan(
            lanes: [.ability],
            abilityTargets: [coding])
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let scope = TotemMemoryTopology.retrievalScope(
            for: plan, subject: subject, ownerID: "o")
        #expect(scope.groups.allSatisfy { !$0.id.hasPrefix("mary-ability-") })
        #expect(!scope.groups.contains { $0.id.hasPrefix("mary-context-") })
        #expect(scope.groups.contains { $0.id.hasPrefix("mary-behavior-interaction-") })
    }

    @Test func behaviorAndStyleAddressesAreStable() {
        let episode = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(TotemMemoryTopology.behaviorDocumentID(episodeID: episode)
                == "mary-behavior-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(TotemMemoryTopology.interactionDocumentID(episodeID: episode)
                == "mary-behavior-interaction-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(TotemMemoryTopology.styleGroup(ownerID: "Owner-ABC").id
                == "mary-style-Owner-ABC")
        #expect(TotemMemoryTopology.interactionGroup(ownerID: "Owner-ABC").id
                == "mary-behavior-interaction-Owner-ABC")
    }
}
