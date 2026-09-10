//
//  CodeSurfaceObserver.swift
//  MaryPlugin
//
//  WHAT: Standing caret grounding for a declared code editor.
//  OUT:  leadContext liveWork  IN: CodeSurfaceEditorCache
//  PIN:  Retracts the caret excerpt when a selection is live; file identity stays.

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation
import os

public final class CodeSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = CodeSurfaceObserver()

    public let id = "code_cursor"

    /// `.workspace` IS THE PER-TURN REFRESH. `installBrainConfiguration`'s turn preparer
    /// refreshes exactly the observers whose senses are non-empty, and a caret read taken
    /// on the last poll rather than at the turn is a caret that may have moved.
    public var ambientSenses: Set<AmbientSense> { [.workspace] }

    /// Slow on purpose, and the same cadence `CorpusObserver` settled on for the same
    /// reason: settling somewhere in a file is a human-scale event.
    public static let pollSeconds: TimeInterval = AmbientFact.cursorRefreshFloor

    private let store: AmbientContextStore
    private let support: CodeSurfaceSupport
    private let corpus: CorpusSupport
    private let poller = SinglePollerClaim()
    /// One read at a time — the poll loop and the per-turn refresh can arrive
    /// together, and a second walk over the same window while one is running
    /// buys nothing.
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// The lane this observer last published into, so a retraction knows which
    /// key to forget without re-deriving a place it may no longer be able to
    /// resolve.
    private let publishedBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    private let lineBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let liveBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let handoffTokens = OSAllocatedUnfairLock<[UUID]>(initialState: [])

    public init(
        store: AmbientContextStore = .shared,
        support: CodeSurfaceSupport = .shared,
        corpus: CorpusSupport = .shared
    ) {
        self.store = store
        self.support = support
        self.corpus = corpus
    }

    // MARK: - MaryObserver

    /// The focused code-surface application, while a caret window is standing.
    /// Nil when this observer has nothing to say, so it does not enter the
    /// arbiter empty and steal a lead from a live writing place.
    public var observedPlace: AmbientPlace? {
        publishedBox.withLock { $0 }
    }

    /// One-line identity for a turn this place did not lead.
    public var ambientLine: String? {
        lineBox.withLock { $0 }
    }

    /// Live window — file, scope, excerpt, deixis.
    public func promptContribution() -> String? {
        liveBox.withLock { $0 }
    }

    /// A WINDOW ONTO THE BUFFER, never the whole file. The speaking lane holds the caret
    /// excerpt; `read_buffer` remains the Skill for a deep read.
    public var holdsWholeDocument: Bool { false }

    public func refreshAmbientContext() async {
        let alreadyWalking = inFlight.withLock({ $0 })
        if alreadyWalking {
            TurnLog.logger.info("observer — turn refresh waited on an in-flight caret walk")
        }
        pollOnce()
        // WAIT FOR AN IN-FLIGHT WALK. The poll loop and the turn preparer share `inFlight`;
        // a turn that arrived mid-walk used to return immediately with an empty `liveBox`,
        // and Lane A spoke the blindness clause before the walk could publish.
        while inFlight.withLock({ $0 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { return }
        }
    }

    public func activate() async {
        poller.claim { [weak self] in
            while !Task.isCancelled {
                // SLEEP FIRST, the observer family's shape: activation runs at
                // boot and on every Settings save.
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.pollOnce()
            }
        }
        pollOnce()
        registerHandoffs()
    }

    public func deactivate() async {
        poller.release()
        unregisterHandoffs()
        retract()
        // A CACHE MUST NOT OUTLIVE THE POLL THAT MAINTAINS IT. Nothing else re-proves this
        // entry, so leaving it primed across a deactivation would hand the next activation
        // an element whose window may have closed in between.
        CodeSurfaceEditorCache.invalidate()
    }

    // MARK: - The poll

    public func pollOnce(at now: Date = Date()) {
        let entered = inFlight.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard entered else { return }
        defer { inFlight.withLock { $0 = false } }

        guard AXIsProcessTrusted() else {
            TurnLog.logger.info("observer — Accessibility not trusted; cannot sample the code editor")
            return
        }

        let standingID = publishedBox.withLock { $0 }?.application
        guard let hit = SurfacePollTarget.pairHit(
            claims: support.all(),
            standingApplicationID: standingID),
              let registration = support.registration(
                applicationID: hit.applicationID)
        else {
            // NOT AN EDITOR TO SAMPLE — and deliberately NOT a retraction.
            TurnLog.logger.info("observer — no code editor to sample")
            return
        }

        let pid = hit.pid
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, CodeSurfaceAX.messagingTimeout)
        let place = AmbientPlace.application(registration.applicationID)
        let bundleID = SurfacePollTarget.runningProcesses().first { $0.pid == pid }?.bundleID
            ?? registration.bundleIdentifiers.first
            ?? registration.applicationID

        guard let window = AX.element(application, kAXFocusedWindowAttribute),
              let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: window, registration: registration)
        else {
            // A FRONTMOST EDITOR WITH NO CARET TO REPORT — no source file open, an
            // unreadable buffer, or a live highlight that owns this ground instead. A
            // BACKGROUND editor that will not read must not retract: the user is speaking
            if hit.isFrontmost {
                let line = "observer — \(registration.displayName) frontmost but no source file (retracted)"
                TurnLog.logger.info("\(line, privacy: .public)")
                retract()
            }
            return
        }

        DeclaredTextSightPublisher.publish(
            place: place, editor: editor, window: window, registration: registration)
        let file = DeclaredTextAX.documentSubject(of: window) ?? registration.displayName
        let selection = CodeSurfaceAX.selectedRange(of: editor)

        if let selection, !selection.isEmpty {
            // Caret excerpt yields; document identity stays while the highlight is live.
            store.forget(key: AmbientKey(place: place, slot: .cursor))
            standFileIdentity(
                place: place, file: file, editorName: registration.displayName,
                bundleID: bundleID, at: now)
            WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
            let published = "observer — looking at \(file) in \(registration.displayName) (highlight)"
            TurnLog.logger.info("\(published, privacy: .public)")
            return
        }

        guard let fact = read(
            editor: editor, window: window, registration: registration,
            place: place, bundleID: bundleID, at: now)
        else {
            if hit.isFrontmost {
                let line = "observer — \(registration.displayName) frontmost but no source file (retracted)"
                TurnLog.logger.info("\(line, privacy: .public)")
                retract()
            }
            return
        }

        store.register(fact, at: now)
        publishedBox.withLock { $0 = place }
        let caretFile = fact.subject ?? registration.displayName
        lineBox.withLock {
            $0 = "In \(registration.displayName): \(caretFile)"
        }
        liveBox.withLock {
            $0 = CodeCursorScope.liveWork(
                editorName: registration.displayName,
                fileName: caretFile,
                content: fact.content)
        }
        WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
        let published = "observer — looking at \(caretFile) in \(registration.displayName)"
        TurnLog.logger.info("\(published, privacy: .public)")
    }

    /// Test seam: the arbiter contract after a caret is standing, without
    /// Accessibility. Production only ever writes these boxes from `pollOnce`.
    func adoptStandingCaretForTests(place: AmbientPlace, line: String, live: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = line }
        liveBox.withLock { $0 = live }
    }

    /// Test seam: file identity standing while a highlight owns the caret slot.
    func adoptStandingFileForTests(place: AmbientPlace, file: String, editorName: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = "In \(editorName): \(file)" }
        liveBox.withLock { $0 = "Looking at \(file) in \(editorName)." }
    }

    /// The fact, or nil when this editor has nothing honest to say about a
    /// caret right now.
    private func read(
        editor: AXUIElement,
        window: AXUIElement,
        registration: CodeSurfaceRegistration,
        place: AmbientPlace,
        bundleID: String,
        at now: Date
    ) -> AmbientFact? {
        // A ZERO-LENGTH RANGE IS A CARET and is the whole point; a non-empty
        // one is a highlight, which belongs to the selection lane (see the
        // header). Nil is "could not read", which is neither.
        guard let selection = CodeSurfaceAX.selectedRange(of: editor),
              selection.isEmpty,
              let total = CodeSurfaceAX.characterCount(of: editor), total > 0
        else { return nil }

        let caret = max(0, min(selection.lowerBound, total))
        let bounds = CodeCursorScope.window(
            around: caret, total: total,
            budget: registration.budgets.ambientExcerptCharacters)
        guard !bounds.isEmpty,
              let raw = CodeSurfaceAX.substring(of: editor, range: bounds)
        else { return nil }
        let excerpt = CodeCursorScope.snapped(
            raw,
            cutAtStart: bounds.lowerBound > 0,
            cutAtEnd: bounds.upperBound < total)

        // THE PREFIX IS THE SCOPE'S ONLY SOURCE and it has to start at 0 —
        // see `CodeCursorScope.scopePrefixCap`. Past the cap the excerpt still
        // publishes and the scope line is simply not claimed.
        var content = excerpt
        if caret <= CodeCursorScope.scopePrefixCap,
           let prefix = caret == 0
            ? "" : CodeSurfaceAX.substring(of: editor, range: 0..<caret) {
            content = CodeCursorScope.content(
                CodeCursorScope.reading(
                    prefix: prefix, excerpt: excerpt,
                    patterns: declarationPatterns(for: registration)))
        }
        guard !content.isEmpty else { return nil }

        return AmbientFact(
            attention: place.attention,
            application: place.application,
            slot: .cursor,
            content: content,
            subject: DeclaredTextAX.documentSubject(of: window),
            applicationID: bundleID,
            // Measured bounds in the editor's own coordinates. `total` is the editor's count.
            bounds: bounds,
            documentTotal: total,
            anchor: .caret,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: now)
    }

    /// The declaration patterns the application's package declared, from the CORPUS
    /// registry — `CodeSurfaceAdapter.listDeclarations`' own note applies verbatim: a
    /// package's.
    private func declarationPatterns(for registration: CodeSurfaceRegistration) -> [String] {
        corpus.registration(applicationID: registration.applicationID)?
            .schema.relations.declarations ?? []
    }

    /// Forget the standing caret and file identity.
    private func retract() {
        let place = publishedBox.withLock { place -> AmbientPlace? in
            defer { place = nil }
            return place
        }
        guard let place else { return }
        lineBox.withLock { $0 = nil }
        liveBox.withLock { $0 = nil }
        store.forget(key: AmbientKey(place: place, slot: .cursor))
        store.forget(key: AmbientKey(place: place, slot: .file))
        DeclaredTextSightStore.shared.clear(place: place)
        if WorkspaceFocusTracker.shared.signal().lookTarget?.place == place {
            WorkspaceFocusTracker.shared.notePaneTarget(nil)
        }
    }

    private func standFileIdentity(
        place: AmbientPlace, file: String, editorName: String,
        bundleID: String, at now: Date
    ) {
        store.register(AmbientFact(
            attention: place.attention,
            application: place.application,
            slot: .file,
            content: file,
            subject: file,
            applicationID: bundleID,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: now), at: now)
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = "In \(editorName): \(file)" }
        liveBox.withLock { $0 = "Looking at \(file) in \(editorName)." }
    }

    private func registerHandoffs() {
        unregisterHandoffs()
        let tokens = DeclaredTextHandoff.register(
            support.all(),
            bundleIdentifiers: { $0.bundleIdentifiers },
            familyPrefix: { $0.bundleIdentifierPrefix },
            ambient: store)
        handoffTokens.withLock { $0 = tokens }
    }

    private func unregisterHandoffs() {
        let tokens = handoffTokens.withLock { current -> [UUID] in
            defer { current = [] }
            return current
        }
        DeclaredTextHandoff.unregister(tokens)
    }
}

/// The support bundle, matching the other observers' shape.
public enum CodeSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [CodeSurfaceObserver.shared] }
}
