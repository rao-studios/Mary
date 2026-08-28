//
//  CorpusObserver.swift
//  MaryAdapters
//
//  WHAT THE USER HAS SETTLED ON, and the crawl it starts.
//
//  WHAT THE ACCESSIBILITY TREE ACTUALLY OFFERS — measured against a real
//  workspace with a real project open, because the design turned on it and the
//  assumption was wrong:
//
//    · `AXDocument` on the workspace window is the PROJECT ROOT
//      (`file:///…/Mary`), NOT the active file. The plan assumed the file;
//      it is the folder, and that turns out to be the better half of the
//      bargain — the source build had to ask over Apple Events for the
//      workspace anchor and Mary gets it free.
//    · The active FILE appears in one place only: the window title, as
//      `Project — Name`.
//    · There is no `AXTextArea` and no per-file `AXDocument` anywhere in the
//      tree. The editor publishes no buffer, which is why the source build
//      shipped whole buffers over Apple Events to read one. The corpus never
//      needed that: it reads the file from DISK, which is also the only
//      trustworthy copy — that build's own notes record the scriptable
//      document as a shadow whose edits the editor pane never takes.
//
//  SO RESOLUTION IS ROOT-FROM-AX PLUS NAME-FROM-TITLE, and a name is not a
//  path. Two files can share a basename, and the doctrine for that is
//  inherited whole from the build this replaces, where it was learned the
//  expensive way: a same-named file in two projects sent an edit into the
//  WRONG repository. AMBIGUITY RESOLVES TO NOTHING. Never a guess, never the
//  first match.
//
//  THE FRESH-EDIT GATE. A file whose last write predates this session is a
//  checkout or another tool's work, not the user's hand — it is indexed for
//  structure and contributes NO style evidence. Reading a colleague's branch
//  must not file the colleague's habits as yours. The source build had a
//  second exclusion here, asking its coding agent "did you write this?"; Mary
//  has no delegated coding yet, and when it lands this is the gate it joins.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class CorpusObserver: MaryObserver, @unchecked Sendable {

    public static let shared = CorpusObserver()

    public let id = "corpus"

    /// What the last completed poll saw.
    private struct Settled: Sendable, Equatable {
        var applicationID: String
        var projectRoot: String
        var projectName: String
        var relativePath: String
    }

    private let settledBox = OSAllocatedUnfairLock<Settled?>(initialState: nil)
    private let poller = SinglePollerClaim()
    /// One crawl at a time. The claim above owns the LOOP; this owns a single
    /// pass, so a per-turn refresh cannot start a second walk over the same
    /// project while one is still reading it.
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let support: CorpusSupport
    /// Set by the runtime; nil means indexing is switched off and the poll
    /// stops before it reads anything.
    private let enabledBox = OSAllocatedUnfairLock<@Sendable () -> Bool>(
        initialState: { true })
    private let sinkBox = OSAllocatedUnfairLock<
        (@Sendable ([IndexedUnit], [StyleObservation], CorpusRegistration) async -> Void)?>(
            initialState: nil)

    /// A write older than this is not this session's editing.
    public static let freshEditWindow: TimeInterval = 30 * 60

    public init(support: CorpusSupport = .shared) {
        self.support = support
    }

    // MARK: - Wiring

    public func setEnabled(_ isEnabled: @escaping @Sendable () -> Bool) {
        enabledBox.withLock { $0 = isEnabled }
    }

    /// Where a completed crawl goes. Injected so this file knows nothing about
    /// Totem, the indexing coordinator, or the style store.
    public func setSink(
        _ sink: @escaping @Sendable ([IndexedUnit], [StyleObservation], CorpusRegistration) async -> Void
    ) {
        sinkBox.withLock { $0 = sink }
    }

    // MARK: - MaryObserver

    public var observedPlace: AmbientPlace? {
        settledBox.withLock { $0 }.map { .application($0.applicationID) }
    }

    public var ambientLine: String? {
        guard let settled = settledBox.withLock({ $0 }) else { return nil }
        return "Working in \(settled.projectName) — \(settled.relativePath)"
    }

    public func promptContribution() -> String? { ambientLine }

    public var ambientSenses: Set<AmbientSense> { [.workspace] }

    public func refreshAmbientContext() async {
        await pollOnce()
    }

    public func activate() async {
        poller.claim { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
            }
        }
        await pollOnce()
    }

    public func deactivate() async {
        poller.release()
        settledBox.withLock { $0 = nil }
    }

    /// Cadence. Slow on purpose: settling on a file is a human-scale event,
    /// and the expensive half of a poll is gated behind the file CHANGING.
    public static let pollSeconds: TimeInterval = 5

    // MARK: - The poll

    /// Read what is in front, and crawl it if it is a unit nobody has settled
    /// on yet.
    public func pollOnce(at now: Date = Date()) async {
        guard enabledBox.withLock({ $0 })() else { return }
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
              let registration = support.registration(bundleID: bundleID),
              let focus = Self.focus(pid: front.processIdentifier, registration: registration)
        else { return }

        let settled = Settled(
            applicationID: registration.applicationID,
            projectRoot: focus.root,
            projectName: focus.projectName,
            relativePath: focus.relativePath)
        // SAME FILE, NOTHING TO DO. The content gate downstream would catch a
        // repeat anyway; stopping here saves reading the whole project to
        // rebuild an index that would answer identically.
        guard settledBox.withLock({ $0 }) != settled else { return }
        settledBox.withLock { $0 = settled }

        guard let sink = sinkBox.withLock({ $0 }) else { return }

        let corpus = registration.schema
        let index = CorpusTypeIndexCache.shared.index(
            root: focus.root, corpus: corpus, at: now
        ) {
            let paths = CorpusCrawl.projectFiles(root: focus.root, corpus: corpus)
            return CorpusTypeIndex(
                root: focus.root,
                files: paths.map { path in
                    (relativePath: path,
                     declaredNames: CorpusCrawl.read(
                        relativePath: path, root: focus.root,
                        corpus: corpus)?.declaredNames ?? [])
                })
        }
        let units = CorpusCrawl.crawl(
            focusedPath: focus.absolutePath,
            root: focus.root,
            projectName: focus.projectName,
            corpus: corpus,
            index: index,
            applicationID: registration.applicationID,
            at: now)
        guard !units.isEmpty else { return }

        // STYLE ONLY FROM A FRESH EDIT, and only from the focused file — the
        // neighbours were pulled in because this one points at them, not
        // because the user just wrote them.
        var observations: [StyleObservation] = []
        if Self.isFreshEdit(focus.absolutePath, at: now),
           let read = CorpusCrawl.read(
            relativePath: focus.relativePath, root: focus.root, corpus: corpus) {
            observations = CorpusStyleReader.observe(
                text: read.text, declaredTypes: read.declaredNames, corpus: corpus)
        }

        // AWAITED, NOT FIRE-AND-FORGET. Two detached ingests have no ordering
        // guarantee, and a stale crawl landing second would pin an older hash
        // into the manifest — a file permanently "changed". The poller claim
        // already serializes crawls, so awaiting here serializes ingests free.
        await sink(units, observations, registration)
    }

    // MARK: - Reading the front

    public struct Focus: Sendable, Equatable {
        public var root: String
        public var projectName: String
        public var relativePath: String
        public var absolutePath: String

        public init(
            root: String, projectName: String,
            relativePath: String, absolutePath: String
        ) {
            self.root = root
            self.projectName = projectName
            self.relativePath = relativePath
            self.absolutePath = absolutePath
        }
    }

    public static func focus(pid: pid_t, registration: CorpusRegistration) -> Focus? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2.0)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let root = documentRoot(of: window),
              let title = string(window, kAXTitleAttribute)
        else { return nil }

        let projectName = (root as NSString).lastPathComponent
        guard let name = activeName(inTitle: title) else { return nil }
        guard let relative = resolve(
            name: name, root: root, corpus: registration.schema)
        else { return nil }

        return Focus(
            root: root,
            projectName: projectName,
            relativePath: relative,
            absolutePath: URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(relative).path)
    }

    /// The workspace folder the window is showing, from its `AXDocument`.
    static func documentRoot(of window: AXUIElement) -> String? {
        guard let raw = string(window, kAXDocumentAttribute) else { return nil }
        let path = URL(string: raw)?.path ?? raw
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return nil }
        // A WINDOW SHOWING A LOOSE FILE gives that file rather than a folder;
        // its project is the folder containing it.
        return isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent
    }

    /// `Project — Name` → `Name`. Nil when the title carries no file, which is
    /// an ordinary state (a settings tab, a welcome window) and not an error.
    static func activeName(inTitle title: String) -> String? {
        // The em dash is the editor's own separator. A title without one is
        // the workspace alone.
        let parts = title.components(separatedBy: " — ")
        guard parts.count >= 2, let last = parts.last else { return nil }
        let name = last.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A NAME IS NOT A PATH. Match it against the project's own units and
    /// insist on exactly one answer — see this file's header for the edit that
    /// went into the wrong repository when a predecessor guessed.
    ///
    /// The title may or may not carry the extension depending on the editor's
    /// display settings, so both spellings are accepted; a name matching no
    /// unit (a settings tab, a file this corpus does not claim) is nothing to
    /// crawl rather than a failure.
    static func resolve(name: String, root: String, corpus: PluginCorpusSchema) -> String? {
        let candidates = CorpusCrawl.projectFiles(root: root, corpus: corpus).filter { path in
            let component = (path as NSString).lastPathComponent
            return component == name
                || (component as NSString).deletingPathExtension == name
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    /// Whether this file was written recently enough to be this session's work.
    public static func isFreshEdit(_ absolutePath: String, at now: Date) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: absolutePath),
              let modified = attributes[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) < freshEditWindow
    }

    // MARK: - AX helpers

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}

/// The support bundle, matching the surface observer's shape.
public enum CorpusObserverSupport {
    public static var all: [any MaryObserver] { [CorpusObserver.shared] }
}
