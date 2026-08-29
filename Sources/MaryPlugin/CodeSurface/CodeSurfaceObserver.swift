//
//  CodeSurfaceObserver.swift
//  MaryPlugin
//
//  STANDING GROUNDING FOR A CODE EDITOR'S CARET — what Mary knows about where
//  the user is working BEFORE she says anything, with no tool call.
//
//  WHAT WAS MISSING. Three lanes already watch an editor and none of them
//  answered this. `CorpusObserver` polls the front project every five seconds
//  and contributes one line of IDENTITY — "Working in Mary — Sources/…/x.swift"
//  — and its own header explains why it can go no further: it reads the
//  project-navigator level, where there is no `AXTextArea` and therefore no
//  buffer. The tier-0 `AmbientSurfaceObserver` publishes a focused ELEMENT
//  (id, role, label, frame) and no text. The selection lane publishes a real
//  highlight and, since `[Corpus W/X/Z]`, mints `interaction.code-selection`
//  from it — but `SelectionHandoffPublisher.captureOutcome` clears its fact on
//  a `.caret` state, so a bare cursor with nothing selected published NOTHING
//  AT ALL. The model's only route to "what am I looking at" was to decide, on
//  its own, to call `read_buffer` first.
//
//  SO THIS IS THE FOURTH THING, AND IT IS THE EYES: the declared excerpt
//  budget's worth of text around the insertion point, the declarations still
//  open above it, and a Bonnie-shaped live section that rides `leadContext`
//  so the speaking lane already holds the window. Corpus keeps the identity
//  line as `ambientLine` and no longer occupies `full`.
//
//  IT PUBLISHES ONLY WHEN NOTHING IS SELECTED, and that is not an
//  optimization. A highlight is a stronger statement of intent than a caret
//  and it already has an owner — the selection handoff, its Interaction, and
//  the `.selection` fact the store accepts only through `recordSelection`.
//  Publishing a cursor fact beside a live highlight would put two claims about
//  "where the user is" in one prompt under two different authorities, which is
//  the hazard the store's whole one-authority ordering exists to close. So
//  when a selection appears this lane RETRACTS and stands down; when it is
//  dropped, the next poll mints the caret again.
//
//  MARY'S WINDOW IS NOT A BLINDNESS. The poll samples the frontmost declared
//  editor when one is in front, and the standing / tracker-led coding
//  workspace when the frontmost process is workspace-transparent (Mary's
//  overlay, system chrome). Asking "what do you think about this code" with
//  Mary's window up is the turn this exists to ground; skipping the walk
//  used to leave `liveWork` empty and Lane A asking for a paste.
//
//  THE 330 MS PROBLEM, AND WHY THIS COULD NOT SHIP BEFORE. Locating the editor
//  element is a bounded tree walk measured at ~330 ms (`CodeSurfaceAX`'s own
//  header); reading attributes off it once located costs ~0.1–0.2 ms. Every
//  existing caller is a Skill handler, where a third of a second is invisible.
//  A poll cannot pay it. `CodeSurfaceEditorCache` is the piece that makes this
//  observer possible at all — see that file for what it re-proves on every
//  hit, which is the one real correctness risk in this feature.
//
//  WHAT IT CONTRIBUTES TO THE PROMPT: the live window. `observedPlace` is the
//  focused registration so the arbiter can grant this observer `leadContext`;
//  `CorpusObserver` still speaks a one-line ambient identity for the same
//  place and must not also fill `full`, or two contributions for one lane
//  would leave the identity line winning and the excerpt on the floor.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class CodeSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = CodeSurfaceObserver()

    public let id = "code_cursor"

    /// `.workspace` IS THE PER-TURN REFRESH. `installBrainConfiguration`'s
    /// turn preparer refreshes exactly the observers whose senses are
    /// non-empty, and a caret read taken on the last poll rather than at the
    /// turn is a caret that may have moved — the same argument that file makes
    /// for refreshing a declared perception there. The sense is honest on its
    /// own terms too: what this reads is where the user is working, which is
    /// what a workspace sense is.
    public var ambientSenses: Set<AmbientSense> { [.workspace] }

    /// Slow on purpose, and the same cadence `CorpusObserver` settled on for
    /// the same reason: settling somewhere in a file is a human-scale event.
    /// `AmbientFact.cursorFreshWindow` is keyed to this number, so the two
    /// cannot drift into a fact that claims freshness the poll never
    /// refreshes.
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

    /// The Bonnie-shaped live window — file, scope, excerpt, deixis.
    public func promptContribution() -> String? {
        liveBox.withLock { $0 }
    }

    /// A WINDOW ONTO THE BUFFER, never the whole file. The speaking lane
    /// holds the caret excerpt; `read_buffer` remains the Skill for a deep
    /// read. Stated here so `MaryRuntime+Focus` cannot promote this lead
    /// into a `.document` world whose only text is a path.
    public var holdsWholeDocument: Bool { false }

    public func refreshAmbientContext() async {
        pollOnce()
        // WAIT FOR AN IN-FLIGHT WALK. The poll loop and the turn preparer
        // share `inFlight`; a turn that arrived mid-walk used to return
        // immediately with an empty `liveBox`, and Lane A spoke the
        // blindness clause before the walk could publish. The outer
        // one-second refresh budget still caps this.
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
    }

    public func deactivate() async {
        poller.release()
        retract()
        // A CACHE MUST NOT OUTLIVE THE POLL THAT MAINTAINS IT. Nothing else
        // re-proves this entry, so leaving it primed across a deactivation
        // would hand the next activation an element whose window may have
        // closed in between.
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

        guard AXIsProcessTrusted() else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let running = NSWorkspace.shared.runningApplications.compactMap {
            application -> CodeSurfacePollTarget.Process? in
            guard let bundleID = application.bundleIdentifier else { return nil }
            return .init(bundleID: bundleID, pid: application.processIdentifier)
        }
        let standingID = publishedBox.withLock { $0 }?.application
        let leadID = WorkspaceFocusTracker.shared.leadPlace()?.application
        let preferred = [standingID, leadID].compactMap { $0 }
        guard let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: front?.bundleIdentifier,
            maryBundleID: Bundle.main.bundleIdentifier,
            registrations: support.all(),
            running: running,
            preferredApplicationIDs: preferred)
        else {
            // NOT AN EDITOR TO SAMPLE — and deliberately NOT a retraction.
            // `AmbientSurfaceObserver` states the rule this follows: "surfaces
            // are NOT retracted on switch … drop-at-expiry is its honesty."
            // Retracting here would be actively wrong, because the commonest
            // reason Xcode stops being frontmost is the user clicking into
            // Mary's own window to ask her something — the exact turn this
            // whole feature exists to ground. `cursorRetention` is what bounds
            // the claim instead, and the fact says its own age either way.
            return
        }

        let pid = hit.pid
        let registration = hit.registration
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, CodeSurfaceAX.messagingTimeout)
        let place = AmbientPlace.application(registration.applicationID)
        let bundleID = running.first { $0.pid == pid }?.bundleID
            ?? registration.bundleIdentifiers.first
            ?? registration.applicationID

        guard let window = AX.element(application, kAXFocusedWindowAttribute),
              let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: window, registration: registration),
              let fact = read(
                editor: editor, window: window, registration: registration,
                place: place, bundleID: bundleID, at: now)
        else {
            // A FRONTMOST EDITOR WITH NO CARET TO REPORT — no source file
            // open, an unreadable buffer, or a live highlight that owns this
            // ground instead. Standing knowledge about a cursor in a file
            // that is no longer open is the confidently-wrong-screen failure,
            // so it goes. A BACKGROUND editor that will not read must not
            // retract: the user is speaking to Mary, and yesterday's caret
            // is still the honest claim until `cursorRetention` expires it.
            if hit.isFrontmost { retract() }
            return
        }

        store.register(fact, at: now)
        publishedBox.withLock { $0 = place }
        let file = fact.subject ?? registration.displayName
        lineBox.withLock {
            $0 = "In \(registration.displayName): \(file)"
        }
        liveBox.withLock {
            $0 = CodeCursorScope.liveWork(
                editorName: registration.displayName,
                fileName: file,
                content: fact.content)
        }
    }

    /// Test seam: the arbiter contract after a caret is standing, without
    /// Accessibility. Production only ever writes these boxes from `pollOnce`.
    func adoptStandingCaretForTests(place: AmbientPlace, line: String, live: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = line }
        liveBox.withLock { $0 = live }
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
            world: place.world,
            application: place.application,
            slot: .cursor,
            content: content,
            subject: Self.subject(of: window),
            applicationID: bundleID,
            // MEASURED BOUNDS, NEVER INVENTED — this is the excerpt's real
            // range in the editor's own character coordinates and `total` is
            // the editor's own count, so `boundsPhrase` can say "characters
            // 5100–5600 of 18234" and be exactly right.
            bounds: bounds,
            documentTotal: total,
            anchor: .caret,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: now)
    }

    /// The declaration patterns the application's package declared, from the
    /// CORPUS registry — `CodeSurfaceAdapter.listDeclarations`' own note
    /// applies verbatim: a package's `corpus` and `codeSurface` blocks sit
    /// side by side under one `applicationID` but live in two registries, and
    /// the patterns are the corpus half's. Empty is a valid answer (a code
    /// surface with no declared outline patterns) and yields a scope line that
    /// says only the caret's line.
    private func declarationPatterns(for registration: CodeSurfaceRegistration) -> [String] {
        corpus.registration(applicationID: registration.applicationID)?
            .schema.relations.declarations ?? []
    }

    /// The file this window is showing, by name. `AXDocument` is a `file://`
    /// URL string — measured, and the reason `CodeSurfaceWriter.fileURL`
    /// exists — and against Xcode specifically it is the ACTIVE FILE rather
    /// than the project root, which is the identity a caret read wants.
    static func subject(of window: AXUIElement) -> String? {
        if let raw = AX.string(window, kAXDocumentAttribute), !raw.isEmpty {
            let path = URL(string: raw)?.path ?? raw
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let title = AX.string(window, kAXTitleAttribute)
        return title?.isEmpty == false ? title : nil
    }

    /// Forget the standing caret, if one is standing.
    private func retract() {
        let place = publishedBox.withLock { place -> AmbientPlace? in
            defer { place = nil }
            return place
        }
        guard let place else { return }
        lineBox.withLock { $0 = nil }
        liveBox.withLock { $0 = nil }
        store.forget(key: AmbientKey(place: place, slot: .cursor))
    }
}

/// The support bundle, matching the other observers' shape.
public enum CodeSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [CodeSurfaceObserver.shared] }
}
