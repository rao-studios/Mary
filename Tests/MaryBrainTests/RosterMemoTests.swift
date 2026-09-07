//
//  RosterMemoTests.swift
//  MaryBrainTests
//
//  WHAT: The roster is arbitrated once per turn, however many times it is asked for.
//  OUT:  AbilityRuntime.rosterArbitration memo
//  PIN:  `projectRoster()` was asked three times per turn, once per lane round
//        and once per DISPATCH, and each arbitrated every Skill again against
//        the same inputs. Pure CPU, paid on every rung of the generic path.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct RosterMemoTests {

    private static func registry() -> AbilityRuntime {
        AbilityRuntime(plugins: [], standalone: [
            SkillBinding(
                name: "poke", description: "test", parameters: [], access: .read,
                backing: .native { _, _ in SkillOutcome(ok: true, summary: "poked") }),
        ]) { AbilityExecutionContext(projects: [:]) }
    }

    @Test func theRosterIsArbitratedOncePerTurn() async {
        let registry = Self.registry()
        registry.beginTurn()
        _ = registry.projectRoster()
        _ = registry.projectRoster()
        _ = registry.projectRoster()
        _ = await registry.dispatch(name: "poke", argumentsJSON: "{}")
        #expect(registry.rosterArbitrationCount == 1)

        // A NEW TURN ARBITRATES AGAIN — the memo is the turn's, not the process's.
        registry.beginTurn()
        _ = registry.projectRoster()
        #expect(registry.rosterArbitrationCount == 2)
    }
}
