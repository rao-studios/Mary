//
//  BehavioralStore.swift
//  MaryRuntime
//
//  WHERE SEALED EPISODES GO — one JSON object per line, one file per day.
//
//  JSONL, and not a database, because of what this is FOR. The episodes are
//  fine-tuning material: they get read once, in bulk, by something that wants
//  every row in order. A line-delimited file is the format that reads well,
//  appends without rewriting, survives a truncated write with the loss of one
//  row, and can be inspected with `tail` at two in the morning. None of that
//  is true of a store that needs a schema migration to add a field.
//
//  THE PRIVACY POSTURE IS DELIBERATE AND IT IS THE OPPOSITE OF THE DEBUG
//  LEDGER'S. Retrieval traces redact: they exist to debug a decision, and the
//  decision is legible without the words. Episodes do not redact, because
//  what the user said and what Mary wrote IS the material — a dataset of
//  redacted turns would teach nothing. So this file writes fact text,
//  selections and document excerpts in plaintext, and everything below is
//  about being honest about that:
//
//    · The directory is 0700 and excluded from backup, so the file does not
//      travel to iCloud or a Time Machine drive by default.
//    · Recording is a setting the user can switch off, and switching it off
//      writes NOTHING — not a reduced row, not a redacted one.
//    · `purge()` deletes every file, because a recording you cannot delete is
//      a recording nobody consented to.
//
//  ONE WRITE PER SEAL, and the seal happens at the end of a turn. An actor
//  rather than a lock: the write is I/O, it must not run on the turn loop,
//  and ordering matters — episodes are appended in seal order and a reader
//  is entitled to assume that.
//

import Foundation
import MaryBrain
import MaryFoundation
import os

public actor BehavioralStore: BehavioralRecording {

    /// `~/Library/Application Support/Mary/behavior`
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Mary", isDirectory: true)
            .appendingPathComponent("behavior", isDirectory: true)
    }

    private let directory: URL
    private let log = Logger(subsystem: "nyc.rao.mary", category: "behavior-store")

    /// Whether anything is written at all.
    ///
    /// READ AT APPEND TIME, not captured at construction, so switching the
    /// setting off takes effect on the next turn rather than the next launch.
    private let isEnabled: @Sendable () -> Bool

    public init(
        directory: URL = BehavioralStore.defaultDirectory(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.directory = directory
        self.isEnabled = isEnabled
    }

    // MARK: - Writing

    public func append(_ episode: BehavioralEpisode) async {
        guard isEnabled() else { return }
        do {
            let line = try BehavioralCodec.encoder().encode(episode)
            try prepareDirectory()
            try appendLine(line, to: file(for: episode.sealedAt ?? episode.openedAt))
        } catch {
            // LOST LOUDLY, IN THIS LOG, AND NOWHERE ELSE. A turn that
            // succeeded must not be reported as failed because a disk was
            // full; the act really happened, and the user has no way to act
            // on a storage problem mid-sentence.
            log.error("episode \(episode.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One file per day, named so `ls` sorts chronologically.
    ///
    /// A DAY, not a size cap. The natural question of this data is "what
    /// happened on the day the thing went wrong", and a rotation on bytes
    /// answers a question nobody asks while making that one hard.
    nonisolated func file(for date: Date) -> URL {
        directory.appendingPathComponent("episodes-\(Self.day.string(from: date)).jsonl")
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func prepareDirectory() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                // 0700 AT CREATION, not chmod'ed afterwards. A directory that
                // is briefly world-readable is world-readable.
                attributes: [.posixPermissions: 0o700])
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(resource)
        }
    }

    /// Append one line, creating the file if it is not there.
    ///
    /// A FILE HANDLE SEEKED TO THE END rather than read-modify-write: the
    /// second grows with the file and would eventually pause a turn for as
    /// long as it takes to load a day of episodes into memory.
    private func appendLine(_ line: Data, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: Data([0x0A]))
    }

    // MARK: - Reading

    /// Every episode on one day, oldest first.
    ///
    /// A CORRUPT LINE IS SKIPPED, NOT FATAL. The last line of the newest file
    /// can be a partial write — the process was killed mid-append — and a
    /// reader that throws on it loses the entire day to save the last row of
    /// it. Skipped lines are counted so a caller can report them.
    public func episodes(on date: Date = Date()) -> (episodes: [BehavioralEpisode], skipped: Int) {
        read(file(for: date))
    }

    /// Every episode in the store, oldest file first.
    public func allEpisodes() -> (episodes: [BehavioralEpisode], skipped: Int) {
        var all: [BehavioralEpisode] = []
        var skipped = 0
        for url in files() {
            let day = read(url)
            all += day.episodes
            skipped += day.skipped
        }
        return (all, skipped)
    }

    /// ONE EPISODE, BY ITS ID — what the run inspector asks for when someone
    /// taps a chip and wants the whole turn rather than one Skill's calls.
    ///
    /// NEWEST DAY FIRST, WITH AN EARLY EXIT. The id is the user turn's UUID
    /// and carries no date, so there is nothing to seek to; but the episode a
    /// person is looking at is almost always today's or yesterday's, and
    /// `allEpisodes()` would load every day in the store to answer a question
    /// the first file usually settles. A miss still costs a full scan, which
    /// is the honest price of an opaque id and is paid off the main actor.
    /// NONISOLATED, along with the two readers it uses. Everything here
    /// touches a `let` URL and the filesystem — nothing the actor protects —
    /// and a full-store scan run ON the actor would sit in front of the next
    /// episode seal, which is a write on a live turn's path. The isolation
    /// exists for the append, not for reading files back.
    public nonisolated func episode(id: UUID) -> BehavioralEpisode? {
        for url in files().reversed() {
            if let match = read(url).episodes.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    private nonisolated func read(_ url: URL) -> (episodes: [BehavioralEpisode], skipped: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        var episodes: [BehavioralEpisode] = []
        var skipped = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let episode = try? BehavioralCodec.decoder().decode(
                BehavioralEpisode.self, from: Data(line)) {
                episodes.append(episode)
            } else {
                skipped += 1
            }
        }
        return (episodes, skipped)
    }

    public nonisolated func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    // MARK: - Deleting

    /// Delete every recorded episode.
    ///
    /// THE WHOLE DIRECTORY, not a per-day choice. Someone reaching for this
    /// wants the recording gone, and a purge that leaves last Tuesday behind
    /// is a purge that did not do what it said.
    @discardableResult
    public func purge() -> Int {
        let removed = files()
        for url in removed { try? FileManager.default.removeItem(at: url) }
        return removed.count
    }

    /// Bytes on disk, for the settings row that offers the purge — a number
    /// is what makes "delete my recordings" a decision rather than a leap.
    public func sizeOnDisk() -> Int {
        files().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
