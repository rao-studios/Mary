//
//  AbilityIntentMemoryTests.swift
//  MaryAmbientTests
//
//  How/where questions consult Ability Totem, keyed by Ability and paradigm,
//  never by the frontmost bundle id.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryFoundation

@Suite struct AbilityIntentMemoryTests {

    @Test func namingACodingAppOpensTheAbilityLane() {
        let profile = ApplicationProfile(
            id: "xcode",
            summary: "A code editor.",
            abilities: [.coding],
            aliases: ["xcode"])
        let gate = AmbientIntentGate.resolve(
            utterance: "how does xcode compile this",
            leadApplicationID: "xcode",
            profiles: [profile])
        #expect(gate.memory.lanes.contains(.ability))
        #expect(gate.memory.abilityTargets.contains {
            $0.abilityID == .coding && $0.paradigm == .discipline
        })
        #expect(!gate.memory.lanes.contains(where: { $0.rawValue == "application" }))
        #expect(gate.memory.expandDisciplineUsage)
        #expect(gate.memory.relationshipHints.contains("practices"))
    }

    @Test func aPersonalQuestionDoesNotRequireAbilityGroups() {
        let gate = AmbientIntentGate.resolve(
            utterance: "who am I",
            leadApplicationID: nil,
            profiles: [])
        #expect(gate.memory.lanes == [.personal])
        #expect(gate.memory.abilityTargets.isEmpty)
        #expect(!gate.memory.expandDisciplineUsage)
    }
}
