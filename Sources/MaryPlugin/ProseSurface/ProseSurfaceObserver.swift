//
//  ProseSurfaceObserver.swift
//  MaryPlugin
//
//  STANDING GROUNDING FOR A PROSE EDITOR'S CARET — the pair-session eyes
//  `CodeSurfaceObserver` already is for code, pointed at declared prose
//  claims. Same poll / standing hit / highlight-outranks-caret / Mary-front
//  contract; the liveWork render is a document window, not a declaration
//  scope.
//
//  No application is named here. Pages, Scrivener, TextEdit arrive as
//  registrations.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class ProseSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = ProseSurfaceObserver()

    public let id = "prose_cursor"
    public var ambientSenses: Set<AmbientSense> { [.workspace] }
    public static let pollSeconds: TimeInterval = AmbientFact.cursorRefreshFloor

    private let store: AmbientContextStore
    private let support: ProseSurfaceSupport
    private let poller = SinglePollerClaim()
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let publishedBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    private let lineBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let liveBox = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init(
        store: AmbientContextStore = .shared,
        support: ProseSurfaceSupport = .shared
    ) {
        self.store = store
        self.support = support
    }

    public var observedPlace: AmbientPlace? {
        publishedBox.withLock { $0 }
    }

    public var ambientLine: String? {
        lineBox.withLock { $0 }
    }

    public func promptContribution() -> String? {
        liveBox.withLock { $0 }
    }

    public var holdsWholeDocument: Bool { false }

    public func refreshAmbientContext() async {
        pollOnce()
        while inFlight.withLock({ $0 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { return }
        }
    }

    public func activate() async {
        poller.claim { [weak self] in
            while !Task.isCancelled {
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
    }

    public func pollOnce(at now: Date = Date()) {
        let entered = inFlight.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard entered else { return }
        defer { inFlight.withLock { $0 = false } }

        guard AXIsProcessTrusted() else { return }

        let standingID = publishedBox.withLock { $0 }?.application
        guard let hit = SurfacePollTarget.pairHit(
            claims: support.all(),
            standingApplicationID: standingID),
              let registration = support.registration(
                applicationID: hit.applicationID)
        else { return }

        let pid = hit.pid
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, DeclaredTextAX.messagingTimeout)
        let place = AmbientPlace.application(registration.applicationID)
        let bundleID = SurfacePollTarget.runningProcesses().first { $0.pid == pid }?.bundleID
            ?? registration.bundleIdentifiers.first
            ?? registration.applicationID

        guard let window = AX.element(application, kAXFocusedWindowAttribute),
              let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: window, registration: registration),
              let fact = read(
                editor: editor, window: window, registration: registration,
                place: place, bundleID: bundleID, at: now)
        else {
            if hit.isFrontmost { retract() }
            return
        }

        store.register(fact, at: now)
        publishedBox.withLock { $0 = place }
        let document = fact.subject ?? registration.displayName
        lineBox.withLock {
            $0 = "In \(registration.displayName): \(document)"
        }
        liveBox.withLock {
            $0 = Self.liveWork(
                editorName: registration.displayName,
                documentName: document,
                excerpt: fact.content)
        }
        WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
    }

    func adoptStandingCaretForTests(place: AmbientPlace, line: String, live: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = line }
        liveBox.withLock { $0 = live }
    }

    private func read(
        editor: AXUIElement,
        window: AXUIElement,
        registration: ProseSurfaceRegistration,
        place: AmbientPlace,
        bundleID: String,
        at now: Date
    ) -> AmbientFact? {
        guard let selection = DeclaredTextAX.selectedRange(of: editor),
              selection.isEmpty,
              let total = DeclaredTextAX.characterCount(of: editor), total > 0
        else { return nil }

        let caret = max(0, min(selection.lowerBound, total))
        let bounds = CodeCursorScope.window(
            around: caret, total: total,
            budget: registration.budgets.ambientExcerptCharacters)
        guard !bounds.isEmpty,
              let raw = DeclaredTextAX.substring(of: editor, range: bounds)
        else { return nil }
        let excerpt = CodeCursorScope.snapped(
            raw,
            cutAtStart: bounds.lowerBound > 0,
            cutAtEnd: bounds.upperBound < total)
        guard !excerpt.isEmpty else { return nil }

        return AmbientFact(
            world: place.world,
            application: place.application,
            slot: .cursor,
            content: excerpt,
            subject: CodeSurfaceObserver.subject(of: window),
            applicationID: bundleID,
            bounds: bounds,
            documentTotal: total,
            anchor: .caret,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: now)
    }

    static func liveWork(
        editorName: String,
        documentName: String,
        excerpt: String
    ) -> String {
        var lines = [
            "Current document:",
            documentName,
            "In \(editorName).",
        ]
        let body = excerpt.trimmingCharacters(in: .newlines)
        if !body.isEmpty {
            lines.append("What they see:\n\(body)")
        }
        lines.append(
            "\"this\" / \"here\" / \"what I just wrote\" refer to this document and selection.")
        lines.append(
            "This snapshot is LIVE and supersedes anything earlier in the conversation about this document — treat older reads of it as stale.")
        return lines.joined(separator: "\n")
    }

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

public enum ProseSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [ProseSurfaceObserver.shared] }
}
