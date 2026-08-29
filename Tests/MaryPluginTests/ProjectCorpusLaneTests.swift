//
//  ProjectCorpusLaneTests.swift
//  MaryPluginTests
//
//  WHICH PROJECT, AND WHICH DOCUMENT — the two resolutions that decide what a
//  ceremony acts on, and the two places where guessing is worse than refusing.
//
//  A manuscript repeats its titles by design: every act has a "Chapter 1", and
//  a writer with two books open has two projects whose names may share a word.
//  Picking the first match in either case reads or edits a DIFFERENT chapter
//  than the one asked for — confidently, with no sign anything went wrong. So
//  both resolvers refuse on ambiguity, and these tests pin that refusal
//  alongside the narrowing rules that keep it from firing too often.
//
//  The live half — the roster, the running application, the project found
//  through its own AXDocument — runs as `mary-corpus-probe project --live`.
//

import Foundation
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class ProjectCorpusLaneTests: XCTestCase {

    // MARK: - Finding one document by title

    private func item(_ title: String, id: String) -> ProjectCorpusReader.Item {
        .init(id: id, title: title, type: "Text", isContainer: false, depth: 0)
    }

    func testAnExactTitleWins() {
        let located = ProjectCorpusAdapter.locate("Chapter 1", in: [
            item("Chapter 1", id: "a"), item("Chapter 10", id: "b"),
        ])
        guard case .one(let found) = located else { return XCTFail("expected one") }
        XCTAssertEqual(found.id, "a")
    }

    /// EXACT BEFORE CONTAINED, and this is the case that makes it matter: with
    /// containment alone, "Chapter 1" matches "Chapter 1", "Chapter 10" and
    /// "Chapter 11", so an exactly-named document becomes unreachable as the
    /// manuscript grows.
    func testAnExactMatchIsNotDrownedByItsOwnPrefixes() {
        let located = ProjectCorpusAdapter.locate("Chapter 1", in: [
            item("Chapter 1", id: "a"), item("Chapter 10", id: "b"),
            item("Chapter 11", id: "c"),
        ])
        guard case .one(let found) = located else {
            return XCTFail("an exact title must still resolve")
        }
        XCTAssertEqual(found.id, "a")
    }

    /// A MANUSCRIPT REPEATS ITS TITLES BY DESIGN — every act has a "Chapter 1".
    /// Picking one would read the wrong chapter with no sign of it.
    func testARepeatedTitleRefusesRatherThanPickingOne() {
        let located = ProjectCorpusAdapter.locate("Chapter 1", in: [
            item("Chapter 1", id: "act-one"), item("Chapter 1", id: "act-two"),
        ])
        guard case .many(let rivals) = located else {
            return XCTFail("a repeated title must refuse")
        }
        XCTAssertEqual(rivals.count, 2)
    }

    func testContainmentResolvesWhenNothingMatchesExactly() {
        let located = ProjectCorpusAdapter.locate("comet", in: [
            item("The Comet Falls", id: "a"), item("Chapter 2", id: "b"),
        ])
        guard case .one(let found) = located else { return XCTFail("expected one") }
        XCTAssertEqual(found.id, "a")
    }

    func testAnEmptyRequestFindsNothingRatherThanEverything() {
        guard case .none = ProjectCorpusAdapter.locate("   ", in: [item("Scene", id: "a")])
        else { return XCTFail("an empty title must match nothing") }
    }

    // MARK: - The evidence a move leaves

    /// A MOVE CHANGES NO COUNT, so the only evidence is the item's parent —
    /// which is why the ceremony compares this map before and after rather
    /// than counting anything.
    func testParentsMapsEveryChildToItsContainer() {
        let tree: [ProjectCorpusReader.Item] = [
            .init(
                id: "act", title: "Act One", type: "Folder", isContainer: true, depth: 0,
                children: [
                    .init(
                        id: "ch", title: "Chapter 1", type: "Folder",
                        isContainer: true, depth: 1,
                        children: [item("Scene", id: "sc")]),
                ]),
        ]
        let parents = ProjectCorpusAdapter.parents(of: tree)
        XCTAssertEqual(parents["ch"], "Act One")
        XCTAssertEqual(parents["sc"], "Chapter 1")
        // A top-level item has no parent, and inventing one would make every
        // ceremony see a move that did not happen.
        XCTAssertNil(parents["act"])
    }

    // MARK: - Which project

    /// A LANE THAT SERVES PROJECTS MUST NOT SERVE A BODY OF SOURCE FILES.
    /// `xcode.mary` declares a corpus with no `structure` — it is learned from
    /// by style and has no outline to read — and the filter is what keeps the
    /// two consumers of one roster apart.
    func testOnlyACorpusWithStructureReachesTheProjectLane() {
        let notation = CorpusRegistration(
            applicationID: "editor", bundleIdentifiers: ["com.example.editor"],
            displayName: "Editor",
            schema: .init(include: ["swift"], notation: "swift"))
        let project = CorpusRegistration(
            applicationID: "manuscripts", bundleIdentifiers: ["com.example.manuscripts"],
            displayName: "Manuscripts",
            schema: .init(
                include: [], notation: "prose",
                structure: .init(
                    discovery: .directoryExtension, projectExtension: "proj",
                    manifest: .init(kind: .fileSystemTree))))

        let support = CorpusSupport()
        support.reconcile([notation, project])
        XCTAssertEqual(support.all.count, 2)
        XCTAssertEqual(support.withStructure.map(\.applicationID), ["manuscripts"])
    }

    /// PREFIX-MATCHED ON PURPOSE: Scrivener's bundle id carries its major
    /// version, so a declaration naming the family must survive the next
    /// release — and `Xcode-beta` must not fall out of a declaration naming
    /// Xcode.
    func testABundleIdentifierMatchesItsVersionedAndBetaVariants() {
        let registration = CorpusRegistration(
            applicationID: "scrivener",
            bundleIdentifiers: ["com.literatureandlatte.scrivener"],
            displayName: "Scrivener",
            schema: .init(include: [], notation: "prose"))
        XCTAssertTrue(registration.owns(bundleID: "com.literatureandlatte.scrivener3"))
        XCTAssertTrue(registration.owns(bundleID: "com.literatureandlatte.scrivener"))
        // Case-insensitively, because a bundle id is not a promise about case.
        XCTAssertTrue(registration.owns(bundleID: "com.LiteratureAndLatte.Scrivener3"))
        // But it is still a prefix, not a substring: a different vendor's app
        // whose id merely contains the name is not this application.
        XCTAssertFalse(registration.owns(bundleID: "com.example.scrivener"))
    }

    // MARK: - Is it safe to drive

    private func corpus(
        openState: [PluginCorpusOpenState], lockFilePath: String?, root: URL,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> OpenCorpus {
        let structure = PluginCorpusStructureSchema(
            discovery: .directoryExtension, projectExtension: "proj",
            openState: openState, lockFilePath: lockFilePath,
            manifest: .init(kind: .fileSystemTree))
        return OpenCorpus(
            registration: .init(
                applicationID: "manuscripts", bundleIdentifiers: ["com.example.manuscripts"],
                displayName: "Manuscripts",
                schema: .init(include: [], notation: "prose", structure: structure)),
            structure: structure,
            projectRoot: root,
            processIdentifier: pid)
    }

    /// THE LOCK IS THE PROJECT'S OWN SIGN that its application has it open,
    /// and its absence means not open — measured live against Scrivener,
    /// where it sits at `Files/user.lock` rather than at the project root. A
    /// path that is merely plausible reports every project as closed, and
    /// reports it silently.
    ///
    /// The two open-state rules are exercised apart on purpose: this process
    /// is not a GUI application, so `NSRunningApplication` does not know it,
    /// and pairing the rules here would test the runner rather than the lock.
    func testAMissingLockMeansTheProjectIsNotOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-\(UUID().uuidString).proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let subject = corpus(
            openState: [.lockFile], lockFilePath: "Files/user.lock", root: root)
        XCTAssertFalse(ProjectCorpusSupport.isOpenForEditing(subject))

        let lock = root.appendingPathComponent("Files/user.lock")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)
        XCTAssertTrue(ProjectCorpusSupport.isOpenForEditing(subject))
    }

    /// A CRASH LEAVES A LOCK BEHIND, which is why the lock is paired with the
    /// process check rather than trusted alone: a project whose owner is gone
    /// is not open, however convincing the file on disk.
    func testAStaleLockDoesNotSurviveTheProcessCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-\(UUID().uuidString).proj")
        let lock = root.appendingPathComponent("Files/user.lock")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: root) }

        // A pid past the system maximum belongs to nothing, which is the
        // shape of an application that has quit since the lock was written.
        let subject = corpus(
            openState: [.lockFile, .runningApplication],
            lockFilePath: "Files/user.lock", root: root, pid: .max)
        XCTAssertFalse(ProjectCorpusSupport.isOpenForEditing(subject))
    }

    /// A plain folder has no owner and is always readable — the case that
    /// keeps the family open to a folder of markdown.
    func testAnAlwaysOpenProjectNeedsNoLock() {
        let subject = corpus(
            openState: [.alwaysOpen], lockFilePath: nil,
            root: FileManager.default.temporaryDirectory)
        XCTAssertTrue(ProjectCorpusSupport.isOpenForEditing(subject))
    }
}
