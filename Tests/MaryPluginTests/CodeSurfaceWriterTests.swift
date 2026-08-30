//
//  CodeSurfaceWriterTests.swift
//  MaryPluginTests
//
//  THE DISK-WRITE PATH'S PURE AND FILE-SYSTEM LOGIC — the parts that need no
//  live Accessibility tree or running Xcode to pin: the clean-buffer gate's
//  own decision function, and the atomic write/re-locate/verify chain
//  against real temporary files. The live half — a real Xcode, a real
//  selection, a real save-vs-unsaved buffer — runs as
//  `mary-corpus-probe --dispatch-code-write` (see that probe's header).
//

import Foundation
import MaryAmbient
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class CodeSurfaceWriterTests: XCTestCase {

    // MARK: - Fixtures

    private static func xcodeLikeRegistration() -> CodeSurfaceRegistration {
        CodeSurfaceRegistration(
            applicationID: "xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            displayName: "Xcode",
            schema: PluginCodeSurfaceSchema(
                handlePrefix: "C",
                editorRoles: [.textArea],
                documentKey: .documentPathThenWindow,
                budgets: .init(
                    wholeDocumentCharacters: 20000,
                    regionCharacters: 4000,
                    ambientExcerptCharacters: 500)))
    }

    /// A real file on disk, cleaned up by the caller. Real Foundation I/O
    /// against a scratch file rather than a mock — the whole point of the
    /// atomic-write path is what the filesystem actually does.
    private func makeScratchFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeSurfaceWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Scratch.swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func snapshot(text: String, path: String, title: String = "Scratch.swift") -> BodySnapshot {
        BodySnapshot(text: text, documentKey: path, documentTitle: title)
    }

    // MARK: - The clean-buffer gate, pure

    func testCleanBufferRefusalIsNilWhenLiveMatchesDisk() {
        let refusal = CodeSurfaceWriter.cleanBufferRefusal(
            live: "func foo() {}", disk: "func foo() {}", documentTitle: "Scratch.swift")
        XCTAssertNil(refusal)
    }

    /// NIL LIVE ABSTAINS RATHER THAN REFUSES — see `CodeSurfaceWriter
    /// .liveBuffer`'s own header: nothing observed live means nothing to
    /// conflict with, and disk is authoritative.
    func testCleanBufferRefusalIsNilWhenLiveIsUnobservable() {
        let refusal = CodeSurfaceWriter.cleanBufferRefusal(
            live: nil, disk: "func foo() {}", documentTitle: "Scratch.swift")
        XCTAssertNil(refusal)
    }

    func testCleanBufferRefusalFiresWhenLiveDivergesFromDisk() {
        let refusal = CodeSurfaceWriter.cleanBufferRefusal(
            live: "func foo() { /* typed but not saved */ }",
            disk: "func foo() {}",
            documentTitle: "Scratch.swift")
        guard case .unsavedChanges(let document) = refusal else {
            return XCTFail("expected .unsavedChanges, got \(String(describing: refusal))")
        }
        XCTAssertEqual(document, "Scratch.swift")
        // NOT AN ERRAND — states the condition and the standing repair.
        let spoken = try! XCTUnwrap(refusal?.errorDescription)
        XCTAssertFalse(spoken.lowercased().contains("save it"), "reads as an imperative: \(spoken)")
    }

    // MARK: - The real write, against a real file

    func testReplaceWritesAtomicallyAndReadsBack() async throws {
        let registration = Self.xcodeLikeRegistration()
        let original = "func greet() {\n    print(\"hello\")\n}\n"
        let file = try makeScratchFile(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // THE CLEAN-BUFFER GATE ABSTAINS HERE: the fixture live-buffer
        // closure answers exactly what is on disk, matching a genuinely
        // saved file.
        let writer = CodeSurfaceWriter(registration: registration, liveBuffer: { _ in original })

        let snap = snapshot(text: original, path: file.path)
        let receipt = try await writer.replace(
            "print(\"hello\")", with: "print(\"hello, world\")",
            hint: 0..<0, in: snap)

        XCTAssertEqual(receipt.method, .diskWrite)
        XCTAssertTrue(receipt.readBack)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "func greet() {\n    print(\"hello, world\")\n}\n")
        XCTAssertEqual(receipt.newBody, onDisk)
        XCTAssertEqual(receipt.newBodyHash, ContentUndoStore.hash(onDisk))
    }

    /// `AXDocument` IS A `file://` URL STRING, NOT A BARE PATH — measured
    /// live against a real Xcode window (`osascript`'s own
    /// `get value of attribute "AXDocument"` answered
    /// `file:///private/tmp/…/Scratch.swift`), and the first version of this
    /// writer's `hasPrefix("/")` check misread every real Xcode document as
    /// never having been saved. This pins the fix: `documentKey` arriving in
    /// its real, measured shape must resolve to the file and write to it.
    func testReplaceResolvesAFileURLDocumentKeyNotJustABarePath() async throws {
        let registration = Self.xcodeLikeRegistration()
        let original = "let x = 1\n"
        let file = try makeScratchFile(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let fileURLKey = file.absoluteString
        XCTAssertTrue(fileURLKey.hasPrefix("file://"), "premise: this is the shape AXDocument answers")

        let writer = CodeSurfaceWriter(registration: registration, liveBuffer: { _ in original })
        let snap = snapshot(text: original, path: fileURLKey)
        let receipt = try await writer.replace("let x = 1", with: "let x = 2", hint: 0..<0, in: snap)

        XCTAssertEqual(receipt.method, .diskWrite)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let x = 2\n")
    }

    /// THE NON-NEGOTIABLE GATE, end to end: a live buffer that disagrees
    /// with disk must refuse before a single byte is written.
    func testReplaceRefusesWhenTheLiveBufferHasUnsavedChanges() async throws {
        let registration = Self.xcodeLikeRegistration()
        let original = "let x = 1\n"
        let file = try makeScratchFile(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let writer = CodeSurfaceWriter(
            registration: registration,
            liveBuffer: { _ in "let x = 1\nlet y = 2 // typed, not yet saved\n" })

        let snap = snapshot(text: original, path: file.path)
        do {
            _ = try await writer.replace("let x = 1", with: "let x = 2", hint: 0..<0, in: snap)
            XCTFail("expected .unsavedChanges to be thrown")
        } catch let error as PassageWriteError {
            guard case .unsavedChanges = error else {
                return XCTFail("expected .unsavedChanges, got \(error)")
            }
        }

        // NOTHING WAS WRITTEN — the file on disk is untouched.
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, original)
    }

    /// A NEVER-SAVED FILE HAS NO DISK LOCATION — `documentKey` falls back to
    /// `"appid:winN"` when Xcode's own `AXDocument` answers empty, and that
    /// is not a path this writer may treat as one.
    func testReplaceRefusesWhenTheDocumentKeyIsNotARealPath() async throws {
        let registration = Self.xcodeLikeRegistration()
        let writer = CodeSurfaceWriter(registration: registration, liveBuffer: { _ in nil })
        let snap = snapshot(text: "let x = 1\n", path: "xcode:win1", title: "Untitled")
        do {
            _ = try await writer.replace("let x = 1", with: "let x = 2", hint: 0..<0, in: snap)
            XCTFail("expected .noDiskLocation to be thrown")
        } catch let error as PassageWriteError {
            guard case .noDiskLocation = error else {
                return XCTFail("expected .noDiskLocation, got \(error)")
            }
        }
    }

    /// WORDS NOT ON DISK ARE `.passageGone`, on the same contract
    /// `ProseSurfaceWriter` satisfies — the writer re-locates in the string
    /// its OWN read just produced rather than trusting a caller's snapshot.
    func testReplaceRefusesWhenThePassageIsNotOnDisk() async throws {
        let registration = Self.xcodeLikeRegistration()
        let original = "let x = 1\n"
        let file = try makeScratchFile(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let writer = CodeSurfaceWriter(registration: registration, liveBuffer: { _ in original })
        let snap = snapshot(text: original, path: file.path)
        do {
            _ = try await writer.replace(
                "this text is not in the file", with: "anything", hint: 0..<0, in: snap)
            XCTFail("expected a refusal")
        } catch is PassageWriteError {
            // Expected — the exact case (.passageGone) is `ProseWriteLocator`'s
            // own contract, pinned by `PassageTests`.
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, original, "a refused locate must never touch the file")
    }
}
