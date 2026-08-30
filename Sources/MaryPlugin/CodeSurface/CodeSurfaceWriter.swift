//
//  CodeSurfaceWriter.swift
//  MaryPlugin
//
//  THE DISK-WRITE PATH — `PassageWriter.diskWrite`'s only implementation,
//  and Bonnie's proven chain for the one application that never let a
//  keystroke land in it: "AppleScript is READ-ONLY for Xcode," and Bonnie's
//  real write path was an atomic temp-file-plus-rename that Xcode's own
//  file watcher picks up and reloads within a second or two, because it
//  watches its open files rather than trusting a scripting layer that has
//  no setter to trust.
//
//  FOUNDATION ONLY, DELIBERATELY. No AppleScript (Xcode's sdef has no write
//  verb to call), no Accessibility SET (`CodeSurfaceAX` is this lane's whole
//  read half and stays that way — `coding.mary`'s own guardrail, "never type
//  prose into a code surface", holds for a synthesized edit too). The one
//  Accessibility read this file makes is the clean-buffer gate below, and it
//  is a READ.
//
//  THE CLEAN-BUFFER GATE, NON-NEGOTIABLE. `PassageEditRunner`'s own header
//  already named the hazard this answers: "Xcode refuses a dirty buffer (its
//  scripting has no save verb)." A disk write cannot ask Xcode whether its
//  buffer is dirty — there is no verb for that either — so this writer asks
//  the only other witness there is: `CodeSurfaceAX`'s live read of the same
//  element `read_buffer` already uses. If the live buffer disagrees with the
//  disk text this writer is about to edit, the user has typing in the editor
//  this write would either silently discard or race against Xcode's own
//  reload — and the only honest move is to refuse and say so, never to guess
//  which one wins.
//
//  CHECKED TWICE, ON PURPOSE. `CodeSurfaceAdapter.replaceSelection` checks it
//  once, up front, so a dirty buffer is refused in its own words rather than
//  surfacing as a confusing "I couldn't find that passage" when the stale
//  disk snapshot no longer contains the live selection's exact text. This
//  writer checks it again, immediately before writing, for the same reason
//  `PassageEditRunner`'s own step 6 re-reads the body hash right before
//  applying an edit: steps 1 through 6 take hundreds of milliseconds, and the
//  user can keep typing the whole time.
//
//  RE-LOCATES IN ITS OWN READ, never in the caller's. `ProseWriteLocator` is
//  reused rather than re-implemented — it is pure text logic with no
//  Accessibility dependency, and the disk text this writer reads is one more
//  candidate string for it to search, on exactly the same contract
//  `ProseSurfaceWriter` already satisfies: re-locate `passageText` in the
//  string THIS API just returned, accept only an unambiguous location, and
//  never convert an offset that arrived from somewhere else.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct CodeSurfaceWriter: PassageWriter {

    public let registration: CodeSurfaceRegistration

    /// The live in-memory buffer for a document key, or nil when nothing
    /// live can be observed there — the application is not running, or that
    /// file is not open in it. INJECTABLE so the clean-buffer gate is
    /// testable with no live Accessibility session: production composes it
    /// from `CodeSurfaceAX`, `CodeSurfaceWriterTests` hands it a fixture.
    ///
    /// NIL MEANS "NOTHING TO CONFLICT WITH", not "assume dirty" — a world
    /// with no live buffer open has no unsaved typing to protect, and disk
    /// is authoritative. In the real flow this writer is reached through
    /// (`replace_selection`, which requires a live selection to have called
    /// it at all) the live buffer is always observable; this default is the
    /// honest answer for the writer used on its own.
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
        // `documentKey` NAMES THE FILE — `documentKey: .documentPathThenWindow`
        // is what every codeSurface package declares, and `CodeSurfaceAX
        // .documentKey` only ever falls back to a window ordinal when
        // `AXDocument` answers empty, which means the file was never saved.
        // MEASURED LIVE, against a real Xcode: `AXDocument` answers a
        // `file://` URL STRING, not a bare path — `CodeSurfaceAX`'s own
        // header already said so ("`AXDocument` is a file URL") and
        // `Self.fileURL` is where that fact gets honored rather than assumed
        // away by a `hasPrefix("/")` check that would misread every real
        // Xcode document as unsaved.
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

    /// Pure, so both call sites — the adapter's up-front check and this
    /// writer's own immediately-before-write check — ask exactly the same
    /// question and cannot drift apart.
    ///
    /// `live == nil` ABSTAINS rather than refusing — see `liveBuffer`'s own
    /// header for why that is the honest answer rather than a loophole.
    static func cleanBufferRefusal(
        live: String?, disk: String, documentTitle: String
    ) -> PassageWriteError? {
        guard let live, live != disk else { return nil }
        return .unsavedChanges(document: documentTitle)
    }

    /// A `codeSurface` document key, resolved to an actual file on disk.
    ///
    /// TWO SHAPES ACCEPTED, on `PluginCodeSurfaceSchema`'s own "the family,
    /// not the application" doctrine: Xcode's `AXDocument` answers a
    /// `file://` URL string — measured live, not assumed — so that is tried
    /// first; a bare absolute path is accepted too, for a future code
    /// surface whose own Accessibility tree answers one directly rather than
    /// a URL. Anything else (the `"appid:winN"` fallback `CodeSurfaceAX`
    /// mints for a document with no `AXDocument` at all, or an empty string)
    /// is honestly nil — there is nowhere on disk this key could name.
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

    /// TEMP FILE, THEN RENAME — same directory as the target so the rename
    /// is on one volume and therefore atomic, and so Xcode's file watcher
    /// sees one filesystem event (a replace) rather than a truncate followed
    /// by a slow refill it could catch mid-write.
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
