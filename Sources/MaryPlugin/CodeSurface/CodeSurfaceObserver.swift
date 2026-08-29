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
//  SO THIS IS THE FOURTH THING, AND IT IS DELIBERATELY THE NARROWEST: the
//  declared excerpt budget's worth of text around the insertion point, and the
//  declarations still open above it.
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
//  THE 330 MS PROBLEM, AND WHY THIS COULD NOT SHIP BEFORE. Locating the editor
//  element is a bounded tree walk measured at ~330 ms (`CodeSurfaceAX`'s own
//  header); reading attributes off it once located costs ~0.1–0.2 ms. Every
//  existing caller is a Skill handler, where a third of a second is invisible.
//  A poll cannot pay it. `CodeSurfaceEditorCache` is the piece that makes this
//  observer possible at all — see that file for what it re-proves on every
//  hit, which is the one real correctness risk in this feature.
//
//  WHAT IT CONTRIBUTES TO THE PROMPT DIRECTLY: nothing. `promptContribution`
//  is nil and `observedPlace` is nil, on `AmbientSurfaceObserver`'s exact
//  reasoning — the output channel is the ambient store, where budget, ranking
//  and lead order are decided once for every lane rather than negotiated per
//  observer. Answering a place here would also enter this observer into the
//  focus arbiter's weighing beside `CorpusObserver`, which already speaks for
//  the same place; two observers voting for one lane is not more evidence, it
//  is the same evidence counted twice.
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
    private let briefBox = OSAllocatedUnfairLock<String?>(initialState: nil)

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

    /// Live identity from the focused registration — file, editor, and a
    /// caret excerpt when one was just published. Distinct from
    /// `CorpusObserver`'s project-root line.
    public func promptContribution() -> String? {
        briefBox.withLock { $0 }
    }

    public func refreshAmbientContext() async { pollOnce() }

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

        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let registration = support.registration(bundleID: bundleID)
        else {
            // NOT AN EDITOR IN FRONT — and deliberately NOT a retraction.
            // `AmbientSurfaceObserver` states the rule this follows: "surfaces
            // are NOT retracted on switch … drop-at-expiry is its honesty."
            // Retracting here would be actively wrong, because the commonest
            // reason Xcode stops being frontmost is the user clicking into
            // Mary's own window to ask her something — the exact turn this
            // whole feature exists to ground. `cursorRetention` is what bounds
            // the claim instead, and the fact says its own age either way.
            return
        }

        let pid = front.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, CodeSurfaceAX.messagingTimeout)
        let place = AmbientPlace.application(registration.applicationID)

        guard let window = AX.element(application, kAXFocusedWindowAttribute),
              let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: window, registration: registration),
              let fact = read(
                editor: editor, window: window, registration: registration,
                place: place, bundleID: bundleID, at: now)
        else {
            // THE EDITOR IS IN FRONT AND HAS NO CARET TO REPORT — no source
            // file open, an unreadable buffer, or a live highlight that owns
            // this ground instead. Standing knowledge about a cursor in a file
            // that is no longer open is the confidently-wrong-screen failure,
            // so it goes.
            retract()
            return
        }

        store.register(fact, at: now)
        publishedBox.withLock { $0 = place }
        let file = Self.subject(of: window) ?? registration.displayName
        briefBox.withLock {
            $0 = "In \(registration.displayName): \(file)"
        }
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
        briefBox.withLock { $0 = nil }
        store.forget(key: AmbientKey(place: place, slot: .cursor))
    }
}

/// The support bundle, matching the other observers' shape.
public enum CodeSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [CodeSurfaceObserver.shared] }
}
