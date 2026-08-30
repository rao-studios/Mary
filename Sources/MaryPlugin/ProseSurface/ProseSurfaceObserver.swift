//
//  ProseSurfaceObserver.swift
//  MaryPlugin
//
//  WHAT: Standing caret grounding for a declared prose editor.
//  IN:   CodeSurfaceObserver contract  OUT: liveWork as a document window

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
    private let handoffTokens = OSAllocatedUnfairLock<[UUID]>(initialState: [])

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
        registerHandoffs()
    }

    public func deactivate() async {
        poller.release()
        unregisterHandoffs()
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
                pid: pid, window: window, registration: registration)
        else {
            if hit.isFrontmost { retract() }
            return
        }

        DeclaredTextSightPublisher.publish(
            place: place, editor: editor, window: window, registration: registration)
        let document = CodeSurfaceObserver.subject(of: window) ?? registration.displayName
        let selection = DeclaredTextAX.selectedRange(of: editor)

        if let selection, !selection.isEmpty {
            store.forget(key: AmbientKey(place: place, slot: .cursor))
            standFileIdentity(
                place: place, file: document, editorName: registration.displayName,
                bundleID: bundleID, at: now)
            WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
            return
        }

        guard let fact = read(
            editor: editor, window: window, registration: registration,
            place: place, bundleID: bundleID, at: now)
        else {
            if hit.isFrontmost { retract() }
            return
        }

        store.register(fact, at: now)
        publishedBox.withLock { $0 = place }
        let caretDocument = fact.subject ?? registration.displayName
        lineBox.withLock {
            $0 = "In \(registration.displayName): \(caretDocument)"
        }
        liveBox.withLock {
            $0 = Self.liveWork(
                editorName: registration.displayName,
                documentName: caretDocument,
                excerpt: fact.content)
        }
        WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
    }

    func adoptStandingCaretForTests(place: AmbientPlace, line: String, live: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = line }
        liveBox.withLock { $0 = live }
    }

    func adoptStandingFileForTests(place: AmbientPlace, file: String, editorName: String) {
        publishedBox.withLock { $0 = place }
        lineBox.withLock { $0 = "In \(editorName): \(file)" }
        liveBox.withLock { $0 = "Looking at \(file) in \(editorName)." }
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
            attention: place.attention,
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

public enum ProseSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [ProseSurfaceObserver.shared] }
}
