//
//  CodeSurfaceWriter.swift
//  MaryPlugin
//
//  WHAT: PassageWriter.diskWrite — atomic temp+rename. Foundation only.
//  IN:   PassageEditRunner APPLY  OUT: file on disk
//  PIN:  Dirty-buffer gate via CodeSurfaceAX read. Relocate in this read.

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct CodeSurfaceWriter: PassageWriter {

    public let registration: CodeSurfaceRegistration

    /// The live in-memory buffer for a document key, or nil when nothing live can be
    /// observed there — the application is not running, or that file is not open in it.
    let liveBuffer: @Sendable (_ documentKey: String) -> String?

    public init(registration: CodeSurfaceRegistration) {
        self.registration = registration
        self.liveBuffer = { documentKey in
            CodeSurfaceWriter.liveBufferViaAccessibility(documentKey, registration: registration)
        }
    }

    /// THE TEST SEAM. Production code never calls this initializer — the
    /// public one above always wires the real Accessibility read.
    init(
        registration: CodeSurfaceRegistration,
        liveBuffer: @escaping @Sendable (_ documentKey: String) -> String?
    ) {
        self.registration = registration
        self.liveBuffer = liveBuffer
    }

    public func replace(
        _ passageText: String,
        with replacement: String,
        hint: Range<Int>,
        in snapshot: BodySnapshot
    ) async throws -> WriteReceipt {
        // `documentKey` NAMES THE FILE — `documentKey: .documentPathThenWindow` is what
        // every codeSurface package.
        guard let url = Self.fileURL(fromDocumentKey: snapshot.documentKey) else {
            throw PassageWriteError.noDiskLocation(document: snapshot.documentTitle)
        }

        // RE-READ, ALWAYS — THIS WRITER'S OWN API. The snapshot may be
        // seconds old; every offset below is into what disk holds RIGHT NOW.
        guard let diskText = try? String(contentsOf: url, encoding: .utf8) else {
            throw PassageWriteError.axRefused(
                detail: "I couldn't read \(snapshot.documentTitle) from disk just now.")
        }

        // THE CLEAN-BUFFER GATE, immediately before touching the file — the
        // second of the two checks this file's header describes.
        if let refusal = Self.cleanBufferRefusal(
            live: liveBuffer(snapshot.documentKey), disk: diskText,
            documentTitle: snapshot.documentTitle) {
            throw refusal
        }

        // RE-LOCATE, in the string this writer's own read just produced —
        // never in `snapshot.text`, which may already be stale.
        let candidate = ProseTextCandidate(resolution: .mainWindowDescent, text: diskText)
        switch ProseWriteLocator.choose(among: [candidate], passageText: passageText, hint: hint) {
        case .refused(let refusal):
            throw refusal.writeError(opening: passageText, document: snapshot.documentTitle)
        case .chosen(let target):
            return try write(
                replacement, into: diskText, at: target.range, url: url, snapshot: snapshot)
        }
    }

    // MARK: - The clean-buffer gate

    /// Pure, so both call sites — the adapter's up-front check and this writer's own
    /// immediately-before-write check — ask exactly the same question and cannot drift
    /// apart.
    static func cleanBufferRefusal(
        live: String?, disk: String, documentTitle: String
    ) -> PassageWriteError? {
        guard let live, live != disk else { return nil }
        return .unsavedChanges(document: documentTitle)
    }

    /// A `codeSurface` document key, resolved to an actual file on disk.
    static func fileURL(fromDocumentKey key: String) -> URL? {
        if let url = URL(string: key), url.isFileURL { return url }
        if key.hasPrefix("/") { return URL(fileURLWithPath: key) }
        return nil
    }

    static func liveBufferViaAccessibility(
        _ documentKey: String, registration: CodeSurfaceRegistration
    ) -> String? {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: { application in
            application.bundleIdentifier.map(registration.owns) ?? false
        })?.processIdentifier else { return nil }
        guard let surface = CodeSurfaceAX.surfaces(pid: pid, registration: registration)
            .first(where: { $0.documentKey == documentKey })
        else { return nil }
        return CodeSurfaceAX.fullString(of: surface.editor)
    }

    // MARK: - The write

    private func write(
        _ replacement: String, into diskText: String, at range: Range<Int>,
        url: URL, snapshot: BodySnapshot
    ) throws -> WriteReceipt {
        let characters = Array(diskText)
        guard range.lowerBound >= 0, range.upperBound <= characters.count else {
            // A stale hint from a caller that outran this read — refuse
            // rather than clamp, `PassageWidening.substring`'s own reason:
            // a clamped write is a write to the wrong place.
            throw PassageWriteError.passageGone(
                opening: SpokenText.truncate(replacement, limit: 60),
                document: snapshot.documentTitle)
        }
        let newText = String(characters[0..<range.lowerBound])
            + replacement
            + String(characters[range.upperBound...])

        do {
            try Self.atomicWrite(newText, to: url)
        } catch let error as PassageWriteError {
            throw error
        } catch {
            throw PassageWriteError.diskWriteFailed(
                document: snapshot.documentTitle, reason: error.localizedDescription)
        }

        // READ BACK — this writer's own next read, the same evidence every
        // other tier reports rather than trusting what was sent.
        let after = try? String(contentsOf: url, encoding: .utf8)
        return WriteReceipt(
            appliedRange: range.lowerBound..<(range.lowerBound + replacement.count),
            newBodyHash: after.map(ContentUndoStore.hash),
            newBody: after,
            readBack: after != nil,
            method: .diskWrite)
    }

    /// TEMP FILE, THEN RENAME — same directory as the target so the rename is on one volume
    /// and therefore.
    static func atomicWrite(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw PassageWriteError.diskWriteFailed(
                document: url.lastPathComponent, reason: "the new text wouldn't encode as UTF-8.")
        }
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".mary-tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
