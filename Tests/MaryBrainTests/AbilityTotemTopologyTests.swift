//
//  AbilityTotemTopologyTests.swift
//  MaryBrainTests
//
//  Ability Totem groups are keyed by ability and paradigm, never by bundle
//  id. New writes mint mary-ability-…; retrieval fans out through
//  relationship hints rather than collapsing projects.
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
        #expect(!a.id.hasPrefix("mary-application-"))
    }

    @Test func personalPlanDoesNotOpenAbilityGroups() {
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let scope = TotemMemoryTopology.retrievalScope(
            for: .personal, subject: subject, ownerID: "o")
        #expect(scope.groups.allSatisfy { !$0.id.hasPrefix("mary-ability-") })
        #expect(scope.groups.allSatisfy { !$0.id.hasPrefix("mary-application-") })
    }

    @Test func abilityPlanRetrievesTheAbilityGroup() {
        let plan = TotemMemoryPlan(
            lanes: [.ability],
            abilityTargets: [coding],
            expandDisciplineUsage: true)
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let scope = TotemMemoryTopology.retrievalScope(
            for: plan, subject: subject, ownerID: "o")
        let expected = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o")
        #expect(scope.groups.map(\.id) == [expected.id])
        #expect(scope.relationshipHints.contains("practices"))
        #expect(scope.relationshipHints.contains("coding"))
        #expect(!scope.groups.contains { $0.id.hasPrefix("mary-scope-") })
    }

    @Test func mixedPlanKeepsProjectScopeAndAbility() {
        let plan = TotemMemoryPlan(
            lanes: [.ability, .personal],
            abilityTargets: [coding],
            expandDisciplineUsage: true)
        let subject = DepositSubject(
            app: "xcode", projectIdentity: "/repos/Mary")
        let scope = TotemMemoryTopology.retrievalScope(
            for: plan, subject: subject, ownerID: "o")
        let ability = TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o")
        #expect(scope.groups.contains { $0.id == ability.id })
        #expect(scope.groups.contains { $0.id.hasPrefix("mary-scope-") })
    }
}
