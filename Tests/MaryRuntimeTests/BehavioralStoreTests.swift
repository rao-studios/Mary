//
//  BehavioralStoreTests.swift
//  MaryRuntimeTests
//
//  WHAT REACHES DISK, AND WHAT MUST NOT.
//
//  Half of these are about durability — an append that lands, a rollover that
//  files the right day, a truncated last line that costs one row instead of a
//  file. The other half are about the promise the store makes to the person
//  whose words are in it: switching recording off writes NOTHING, and a purge
//  leaves nothing behind. Those two are the ones worth breaking a build over,
//  because a bug in either is a bug in what somebody consented to.
//

import Foundation
import os
import Testing
import MaryBrain
import MaryFoundation
@testable import MaryRuntime

@Suite struct BehavioralStoreTests {

    /// A store in its own temporary directory, removed after the body runs.
    private func withStore(
        enabled: @escaping @Sendable () -> Bool = { true },
        _ body: (BehavioralStore, URL) async throws -> Void
    ) async rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-behavior-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(BehavioralStore(directory: directory, isEnabled: enabled), directory)
    }

    private func episode(
        _ query: String, at date: Date = Date(), actions: Int = 0
    ) -> BehavioralEpisode {
        var episode = BehavioralEpisode(
            id: UUID(), openedAt: date,
            input: BehavioralInput(query: query),
            provenance: EpisodeProvenance(
                engine: "local", lane: "dual", appVersion: "test"))
        for index in 0..<actions {
            episode.output.actions.append(BehavioralActionRecord(
                id: "run-\(index)",
                action: BehavioralAction(
                    intention: "act_\(index)", argumentsJSON: "{}",
                    skill: AbilitySkillReference(
                        packageID: PackageID(rawValue: "writing")!,
                        packageVersion: SemanticVersion("1.0.0"),
                        abilityID: .writing, abilityTitle: "Writing", abilityTint: "blue",
                        skillID: SkillID(rawValue: "write")!, skillTitle: "Write",
                        invocationName: "act_\(index)")),
                disposition: .succeeded, summary: "done", startedAt: date))
        }
        episode.seal(.completed, at: date)
        return episode
    }

    // MARK: - Round trip

    @Test func anAppendedEpisodeReadsBackWhole() async throws {
        try await withStore { store, _ in
            let written = episode("tidy the note", actions: 2)
            await store.append(written)

            let read = await store.allEpisodes()
            #expect(read.skipped == 0)
            #expect(read.episodes.count == 1)
            #expect(read.episodes[0].id == written.id)
            #expect(read.episodes[0].input.query == "tidy the note")
            #expect(read.episodes[0].output.actions.map(\.action.intention)
                    == ["act_0", "act_1"])
            #expect(read.episodes[0].sealedReason == .completed)
        }
    }

    /// APPEND ORDER IS SEAL ORDER, and a reader is entitled to assume it.
    @Test func episodesComeBackInTheOrderTheyWereSealed() async throws {
        try await withStore { store, _ in
            for query in ["first", "second", "third"] {
                await store.append(episode(query))
            }
            let read = await store.allEpisodes()
            #expect(read.episodes.map(\.input.query) == ["first", "second", "third"])
        }
    }

    @Test func oneLinePerEpisode() async throws {
        try await withStore { store, directory in
            for _ in 0..<3 { await store.append(episode("q")) }
            let file = await store.files().first
            let text = try String(contentsOf: try #require(file), encoding: .utf8)
            #expect(text.split(separator: "\n").count == 3)
            #expect(directory.path.contains("mary-behavior"))
        }
    }

    // MARK: - The day

    @Test func episodesAreFiledUnderTheDayTheySealed() async throws {
        try await withStore { store, _ in
            let today = Date()
            let yesterday = today.addingTimeInterval(-60 * 60 * 24)
            await store.append(episode("old", at: yesterday))
            await store.append(episode("new", at: today))

            #expect(await store.files().count == 2, "one file per day")
            let onlyToday = await store.episodes(on: today)
            #expect(onlyToday.episodes.map(\.input.query) == ["new"])
        }
    }

    // MARK: - Damage

    /// A TRUNCATED LAST LINE COSTS ONE ROW, not the file. The process can be
    /// killed mid-append, and a reader that throws on the partial row loses
    /// the whole day to save the last line of it.
    @Test func aTruncatedLineIsSkippedAndTheRestSurvives() async throws {
        try await withStore { store, _ in
            await store.append(episode("intact one"))
            await store.append(episode("intact two"))
            let file = try #require(await store.files().first)

            // Simulate a kill mid-write: a half-object with no newline.
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"schema":"mary.behav"#.utf8))
            try handle.close()

            let read = await store.allEpisodes()
            #expect(read.episodes.count == 2)
            #expect(read.skipped == 1, "the partial row was not counted")
        }
    }

    @Test func anEmptyStoreReadsAsEmptyRatherThanFailing() async throws {
        try await withStore { store, _ in
            let read = await store.allEpisodes()
            #expect(read.episodes.isEmpty)
            #expect(read.skipped == 0)
            #expect(await store.sizeOnDisk() == 0)
        }
    }

    // MARK: - The promises

    /// SWITCHED OFF WRITES NOTHING — not a reduced row, not a redacted one,
    /// not a file. This is the test that has to hold for the setting to mean
    /// what its label says.
    @Test func recordingSwitchedOffLeavesNoTrace() async throws {
        try await withStore(enabled: { false }) { store, directory in
            for _ in 0..<5 { await store.append(episode("private")) }

            #expect(await store.files().isEmpty)
            #expect(await store.allEpisodes().episodes.isEmpty)
            #expect(
                !FileManager.default.fileExists(atPath: directory.path),
                "the directory itself must not be created")
        }
    }

    /// AND THE SETTING IS READ PER APPEND, so switching it off takes effect on
    /// the next turn rather than the next launch.
    @Test func switchingOffMidSessionStopsTheNextWrite() async throws {
        let recording = OSAllocatedUnfairLock(initialState: true)
        try await withStore(enabled: { recording.withLock { $0 } }) { store, _ in
            await store.append(episode("recorded"))
            recording.withLock { $0 = false }
            await store.append(episode("not recorded"))

            let read = await store.allEpisodes()
            #expect(read.episodes.map(\.input.query) == ["recorded"])
        }
    }

    /// A RECORDING YOU CANNOT DELETE IS A RECORDING NOBODY CONSENTED TO.
    @Test func purgeLeavesNothingBehind() async throws {
        try await withStore { store, _ in
            let today = Date()
            await store.append(episode("today", at: today))
            await store.append(episode("yesterday", at: today.addingTimeInterval(-86_400)))
            #expect(await store.sizeOnDisk() > 0)

            let removed = await store.purge()
            #expect(removed == 2, "a purge that leaves last Tuesday is not a purge")
            #expect(await store.files().isEmpty)
            #expect(await store.allEpisodes().episodes.isEmpty)
            #expect(await store.sizeOnDisk() == 0)
        }
    }

    /// THE DIRECTORY IS 0700 AT CREATION, not chmod'ed afterwards — a
    /// directory that is briefly world-readable is world-readable.
    @Test func theDirectoryIsPrivateAndExcludedFromBackup() async throws {
        try await withStore { store, directory in
            await store.append(episode("q"))

            let attributes = try FileManager.default
                .attributesOfItem(atPath: directory.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o700)

            let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(excluded.isExcludedFromBackup == true)
        }
    }

    // MARK: - The codec's own guarantee, end to end

    /// SUB-SECOND ORDER SURVIVES THE ROUND TRIP. Actions land 100–300 ms
    /// apart, and a whole-second timestamp would collapse them into the same
    /// instant — destroying the sequence, which is the one thing a plan is.
    @Test func actionsMillisecondsApartKeepTheirOrderOnDisk() async throws {
        try await withStore { store, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            var written = episode("three quick acts", at: base)
            written.output.actions = (0..<3).map { index in
                BehavioralActionRecord(
                    id: "run-\(index)",
                    action: BehavioralAction(
                        intention: "act_\(index)", argumentsJSON: "{}",
                        skill: AbilitySkillReference(
                            packageID: PackageID(rawValue: "writing")!,
                            packageVersion: SemanticVersion("1.0.0"),
                            abilityID: .writing, abilityTitle: "Writing",
                            abilityTint: "blue",
                            skillID: SkillID(rawValue: "write")!, skillTitle: "Write",
                            invocationName: "act_\(index)")),
                    disposition: .succeeded, summary: "done",
                    // Exact binary fractions, so equality survives the encode.
                    startedAt: base.addingTimeInterval(Double(index) * 0.125))
            }
            await store.append(written)

            let read = try #require(await store.allEpisodes().episodes.first)
            let stamps = read.output.actions.map(\.startedAt)
            #expect(stamps == written.output.actions.map(\.startedAt))
            #expect(Set(stamps).count == 3, "three acts collapsed into one instant")
        }
    }
}
