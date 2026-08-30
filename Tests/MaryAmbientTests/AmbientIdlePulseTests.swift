//
//  AmbientIdlePulseTests.swift
//  MaryAmbientTests
//
//  Life pulses only when the world is quiet: no open turn, no running skill,
//  indexing settled, and enough time since the last user episode.
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientIdlePulseTests {

    private let now = Date(timeIntervalSince1970: 1_787_821_200)

    @Test func doesNotFireWhileATurnIsOpen() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: true,
            isSkillRunning: false,
            lastUserEpisodeAt: now.addingTimeInterval(-120),
            now: now)
        #expect(!AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func doesNotFireWhileASkillIsRunning() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: true,
            lastUserEpisodeAt: now.addingTimeInterval(-120),
            now: now)
        #expect(!AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func doesNotFireWhileIndexingIsPending() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: false,
            isWorkspaceIndexing: true,
            lastUserEpisodeAt: now.addingTimeInterval(-120),
            now: now)
        #expect(!AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func doesNotFireUntilQuietAfterTheLastUserEpisode() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: false,
            lastUserEpisodeAt: now.addingTimeInterval(-10),
            now: now)
        #expect(!AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func firesAfterQuiet() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: false,
            lastUserEpisodeAt: now.addingTimeInterval(-60),
            now: now)
        #expect(AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func firesWhenThereHasBeenNoUserEpisodeYet() {
        let conditions = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: false,
            lastUserEpisodeAt: nil,
            now: now)
        #expect(AmbientIdlePulse.shouldFire(conditions))
    }

    @Test func abilityHintPrefersAReadyDisciplineOnTheLeadPlace() {
        let lead = AmbientPlace.application("textedit")
        let profiles = [
            ApplicationProfile(
                id: "textedit",
                summary: "Notes.",
                abilities: [.writing, .coding])
        ]
        let hint = AmbientIdlePulse.abilityHint(
            lead: lead,
            profiles: profiles,
            readyDisciplines: [.writing],
            abilities: DisciplineIndex())
        #expect(hint?.abilityID == .writing)
        #expect(hint?.paradigm == .discipline)
    }

    @Test func sourceEmitsOnePulseAtATime() async {
        let source = AmbientIdlePulseSource()
        let quiet = AmbientIdlePulse.Conditions(
            isTurnInFlight: false,
            isSkillRunning: false,
            lastUserEpisodeAt: now.addingTimeInterval(-60),
            now: now)
        let first = await source.beginIfReady(
            conditions: quiet,
            store: AmbientContextStore.shared,
            profiles: [],
            readyDisciplines: [])
        #expect(first != nil)
        let second = await source.beginIfReady(
            conditions: quiet,
            store: AmbientContextStore.shared,
            profiles: [],
            readyDisciplines: [])
        #expect(second == nil)
        await source.endPulse()
        let third = await source.beginIfReady(
            conditions: quiet,
            store: AmbientContextStore.shared,
            profiles: [],
            readyDisciplines: [])
        #expect(third != nil)
        await source.endPulse()
    }
}

private struct DisciplineIndex: AbilityCapabilityIndex {
    var revision: UUID { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
    func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    func paradigm(of _: AbilityID) -> AbilityParadigm? { .discipline }
}
