//
//  ApplicationHabitLedger.swift
//  MaryBrain
//
//  WHAT: Which application this person reaches for, per discipline, decayed.
//  IN:   a granted successful dispatch that landed in a known application
//  OUT:  ExpertiseResolution's ranking; the rehearsal's third tier
//  PIN:  FACTS CLIFF; HABITS DRIFT — the weighting is `StyleRecency`'s, not a
//        second half-life of its own. A vote halves every thirty days, so a
//        fortnight of Spotify overtakes a year of Apple Music without anyone
//        setting a preference, and going back reverses it just as quietly.
//        NO NEGATIVE ROWS. An act that failed says nothing about which player
//        this person prefers, and recording it would let one bad AX night
//        unseat a settled habit — the same reason the habit chokepoint
//        teaches successes only.
//
import Foundation
import MaryAmbient
import MaryFoundation
import os

/// One act, in one application, under one discipline.
public struct ApplicationHabit: Sendable, Codable, Equatable {
    /// The discipline whose Skill ran (`multimedia`).
    public var disciplineID: AbilityID
    /// The application-expertise Ability that answered it (`apple-music`).
    public var expertiseID: AbilityID
    /// That expertise's logical application id, denormalized so a ranking can
    /// be turned into an `app` argument without re-reading the registry.
    public var applicationID: String
    /// Which Skill proved it — kept for the ledger's own legibility.
    public var skillID: String
    public var observedAt: Date

    public init(
        disciplineID: AbilityID,
        expertiseID: AbilityID,
        applicationID: String,
        skillID: String,
        observedAt: Date = Date()
    ) {
        self.disciplineID = disciplineID
        self.expertiseID = expertiseID
        self.applicationID = applicationID
        self.skillID = skillID
        self.observedAt = observedAt
    }
}

public final class ApplicationHabitLedger: @unchecked Sendable {

    public static let shared = ApplicationHabitLedger()

    /// Reused, never redefined — one decay curve in the codebase.
    public static let halfLife = StyleRecency.halfLife
    public static let decayFloor = StyleRecency.decayFloor
    /// Rows kept per discipline. Well past the point where further rows can
    /// change a ranking; the cap exists so a ledger cannot grow without bound.
    public static let perDisciplineCap = 120

    private let box = OSAllocatedUnfairLock<[ApplicationHabit]>(initialState: [])

    /// `memory` is resolved per call rather than captured, so installing a
    /// backend after the shared ledger exists still takes effect.
    private let memoryOverride: (any ApplicationHabitMemory)?

    public init(memory: (any ApplicationHabitMemory)? = nil) {
        self.memoryOverride = memory
    }

    private var memory: any ApplicationHabitMemory {
        memoryOverride ?? ApplicationHabitMemoryProvider.current
    }

    // MARK: - Learning

    /// Teach the ledger, and make the habit usable at once — a turn that
    /// dispatches twice should see the first vote on the second read.
    public func record(_ habit: ApplicationHabit, now: Date = Date()) {
        let live = box.withLock { rows -> [ApplicationHabit] in
            rows.append(habit)
            rows = Self.capped(Self.pruned(rows, now: now))
            return rows.filter { $0.disciplineID == habit.disciplineID }
        }
        let memory = self.memory
        let discipline = habit.disciplineID
        // FIRE AND FORGET: a turn must never wait to be taught.
        Task.detached { await memory.remember(live, discipline: discipline) }
    }

    /// Load what personal memory holds for these disciplines, replacing the
    /// in-memory view for each. Called at launch and on every registry
    /// activation, so a newly installed discipline is restored too.
    public func restore(disciplines: [AbilityID]) async {
        guard !disciplines.isEmpty else { return }
        let memory = self.memory
        var restored: [ApplicationHabit] = []
        for discipline in disciplines {
            restored.append(contentsOf: await memory.recall(discipline: discipline))
        }
        let wanted = Set(disciplines)
        box.withLock { rows in
            // Keep any discipline this restore did not ask about; replace the
            // ones it did.
            rows = Self.capped(Self.pruned(
                rows.filter { !wanted.contains($0.disciplineID) } + restored,
                now: Date()))
        }
    }

    /// Drop one discipline's history. The forget is durable — an emptied
    /// ledger is deposited, exactly as `depositStyleProfile` treats a forget.
    public func forget(discipline: AbilityID) {
        box.withLock { rows in
            rows.removeAll { $0.disciplineID == discipline }
        }
        let memory = self.memory
        Task.detached { await memory.remember([], discipline: discipline) }
    }

    // MARK: - Reading

    /// Live rows for one discipline, decayed rows already swept.
    public func habits(
        for discipline: AbilityID, now: Date = Date()
    ) -> [ApplicationHabit] {
        box.withLock { $0 }
            .filter { $0.disciplineID == discipline }
            .filter { Self.weight(of: $0, now: now) >= Self.decayFloor }
    }

    /// Summed recency weight per expertise. THE RANKING ITSELF — a count would
    /// let a year-old routine outvote this month's, which is the whole thing
    /// this ledger exists to avoid.
    public func weights(
        for discipline: AbilityID, now: Date = Date()
    ) -> [AbilityID: Double] {
        var totals: [AbilityID: Double] = [:]
        for row in habits(for: discipline, now: now) {
            totals[row.expertiseID, default: 0] += Self.weight(of: row, now: now)
        }
        return totals
    }

    public func lastSeen(
        discipline: AbilityID, expertise: AbilityID, now: Date = Date()
    ) -> Date? {
        habits(for: discipline, now: now)
            .filter { $0.expertiseID == expertise }
            .map(\.observedAt)
            .max()
    }

    public var count: Int { box.withLock { $0 }.count }

    // MARK: - Time

    private static func weight(of habit: ApplicationHabit, now: Date) -> Double {
        StyleRecency.weight(at: habit.observedAt, now: now, halfLife: halfLife)
    }

    /// Below the floor a vote stops counting and is swept — two half-lives,
    /// the same cliff `StyleEvidence` uses.
    private static func pruned(
        _ rows: [ApplicationHabit], now: Date
    ) -> [ApplicationHabit] {
        rows.filter { weight(of: $0, now: now) >= decayFloor }
    }

    /// Oldest first out, per discipline.
    private static func capped(_ rows: [ApplicationHabit]) -> [ApplicationHabit] {
        var byDiscipline: [AbilityID: [ApplicationHabit]] = [:]
        for row in rows.sorted(by: { $0.observedAt < $1.observedAt }) {
            var bucket = byDiscipline[row.disciplineID, default: []]
            bucket.append(row)
            if bucket.count > perDisciplineCap {
                bucket.removeFirst(bucket.count - perDisciplineCap)
            }
            byDiscipline[row.disciplineID] = bucket
        }
        return byDiscipline.values.flatMap { $0 }
            .sorted { $0.observedAt < $1.observedAt }
    }
}
