//
//  ApplicationHabitLedgerTests.swift
//  MaryBrainTests
//
//  WHAT: Habits decay, so switching players re-ranks them without a setting.
//  OUT:  ApplicationHabitLedger.weights / habits / restore / forget
//  PIN:  The point of the half-life is that a NEWER, SMALLER streak wins.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct ApplicationHabitLedgerTests {

    private let multimedia = AbilityID("multimedia")
    private let appleMusic = AbilityID("apple-music")
    private let spotify = AbilityID("spotify")

    /// Records what the ledger asked personal memory to store, and answers
    /// restores from a script — the `RecordingMemory` shape the habit
    /// tests use.
    private final class RecordingMemory: ApplicationHabitMemory, @unchecked Sendable {
        var remembered: [(habits: [ApplicationHabit], discipline: AbilityID)] = []
        var script: [AbilityID: [ApplicationHabit]] = [:]
        private let lock = NSLock()

        func remember(_ habits: [ApplicationHabit], discipline: AbilityID) async {
            lock.lock(); defer { lock.unlock() }
            remembered.append((habits, discipline))
        }

        func recall(discipline: AbilityID) async -> [ApplicationHabit] {
            lock.lock(); defer { lock.unlock() }
            return script[discipline] ?? []
        }
    }

    private func habit(
        _ expertise: AbilityID, at date: Date
    ) -> ApplicationHabit {
        ApplicationHabit(
            disciplineID: multimedia,
            expertiseID: expertise,
            applicationID: expertise.rawValue,
            skillID: "multimedia.play-playlist",
            observedAt: date)
    }

    /// THE WHOLE POINT. Twelve Apple Music acts fifty days ago lose to five
    /// Spotify acts yesterday — the person moved, and nothing was configured.
    @Test func aRecentStreakOvertakesAnOlderHabit() {
        let now = Date()
        let ledger = ApplicationHabitLedger(memory: RecordingMemory())
        for _ in 0..<12 {
            ledger.record(
                habit(appleMusic, at: now.addingTimeInterval(-50 * 86_400)), now: now)
        }
        for _ in 0..<5 {
            ledger.record(
                habit(spotify, at: now.addingTimeInterval(-86_400)), now: now)
        }
        let weights = ledger.weights(for: multimedia, now: now)
        let apple = weights[appleMusic] ?? 0
        let spot = weights[spotify] ?? 0
        #expect(spot > apple, "5 recent acts (\(spot)) should outweigh 12 old ones (\(apple))")
    }

    /// The same rows, read back at the older moment, rank the other way —
    /// proving the ordering is time, not insertion.
    @Test func theSameRowsRankedEarlierFavourTheOlderHabit() {
        let now = Date()
        let past = now.addingTimeInterval(-49 * 86_400)
        let ledger = ApplicationHabitLedger(memory: RecordingMemory())
        for _ in 0..<12 {
            ledger.record(
                habit(appleMusic, at: now.addingTimeInterval(-50 * 86_400)), now: now)
        }
        let weights = ledger.weights(for: multimedia, now: past)
        #expect((weights[appleMusic] ?? 0) > 0)
        #expect(weights[spotify] == nil)
    }

    /// Below two half-lives a vote stops counting and is swept.
    @Test func aVoteBelowTheFloorIsGone() {
        let now = Date()
        let ledger = ApplicationHabitLedger(memory: RecordingMemory())
        // Three half-lives back — weight 0.125, under the 0.25 floor.
        ledger.record(
            habit(appleMusic, at: now.addingTimeInterval(-90 * 86_400)), now: now)
        #expect(ledger.habits(for: multimedia, now: now).isEmpty)
        #expect(ledger.weights(for: multimedia, now: now).isEmpty)
    }

    @Test func aVoteIsUsableImmediatelyAndIsTaught() async throws {
        let memory = RecordingMemory()
        let ledger = ApplicationHabitLedger(memory: memory)
        ledger.record(habit(appleMusic, at: Date()))
        #expect(ledger.weights(for: multimedia)[appleMusic] != nil)
        // The deposit is detached; give it a moment to land.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(memory.remembered.contains { $0.discipline == self.multimedia })
    }

    @Test func restoreReplacesTheView() async {
        let memory = RecordingMemory()
        memory.script[multimedia] = [habit(spotify, at: Date())]
        let ledger = ApplicationHabitLedger(memory: memory)
        ledger.record(habit(appleMusic, at: Date()))
        await ledger.restore(disciplines: [multimedia])
        let weights = ledger.weights(for: multimedia)
        #expect(weights[spotify] != nil)
        #expect(weights[appleMusic] == nil, "restore replaces, it does not merge")
    }

    @Test func forgettingIsDurable() async throws {
        let memory = RecordingMemory()
        let ledger = ApplicationHabitLedger(memory: memory)
        ledger.record(habit(appleMusic, at: Date()))
        ledger.forget(discipline: multimedia)
        #expect(ledger.weights(for: multimedia).isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        // An EMPTY ledger deposited over the old one — that is the forget.
        #expect(memory.remembered.last?.habits.isEmpty == true)
    }

    @Test func theLedgerIsCapped() {
        let now = Date()
        let ledger = ApplicationHabitLedger(memory: RecordingMemory())
        for index in 0..<(ApplicationHabitLedger.perDisciplineCap + 40) {
            ledger.record(
                habit(appleMusic, at: now.addingTimeInterval(-Double(index))), now: now)
        }
        #expect(
            ledger.habits(for: multimedia, now: now).count
                <= ApplicationHabitLedger.perDisciplineCap)
    }
}
