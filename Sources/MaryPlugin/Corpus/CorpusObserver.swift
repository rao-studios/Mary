//
//  CorpusObserver.swift
//  MaryPlugin
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
    /// Identity of the last structure crawl that produced units, so a view
    /// that has not grown neighbours can skip the sink without skipping the
    /// walk that would discover them.
    private let lastStructureBox = OSAllocatedUnfairLock<String?>(initialState: nil)
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

    /// Identity only. The live buffer window belongs to `CodeSurfaceObserver`;
    /// putting this line in `full` made it occupy `leadContext` and left the
    /// voice with a path instead of source.
    public func promptContribution() -> String? { nil }

    public var ambientSenses: Set<AmbientSense> { [.workspace] }

    public func refreshAmbientContext() async {
        await pollOnce()
        while inFlight.withLock({ $0 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { return }
        }
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
        lastStructureBox.withLock { $0 = nil }
    }

    /// Cadence. Slow on purpose: settling on a file is a human-scale event.
    /// Viewing is enough to crawl structure and neighbours; a fresh edit is
    /// only required for style.
    public static let pollSeconds: TimeInterval = 5

    /// Identity of a crawl's structure, so a view can retry neighbours
    /// without re-sending an unchanged neighbourhood.
    package static func structureKey(for units: [IndexedUnit]) -> String {
        units.map {
            "\($0.relativePath)|\($0.contentHash)|\($0.neighbours.sorted().joined(separator: ","))"
        }.sorted().joined(separator: ";")
    }

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

        guard AXIsProcessTrusted() else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let frontBundleID = front?.bundleIdentifier
        let targeted: (registration: CorpusRegistration, pid: pid_t)?
        if let front, let frontBundleID,
           let registration = support.registration(bundleID: frontBundleID) {
            targeted = (registration, front.processIdentifier)
        } else if WorkspaceFocusTracker.isWorkspaceTransparent(bundleID: frontBundleID) {
            let preferred = [
                settledBox.withLock { $0 }?.applicationID,
                WorkspaceFocusTracker.shared.leadPlace()?.application,
            ].compactMap { $0 }
            targeted = Self.standingCorpus(
                preferredApplicationIDs: preferred, support: support)
        } else {
            targeted = nil
        }
        guard let targeted,
              let focus = Self.focus(
                pid: targeted.pid, registration: targeted.registration)
        else { return }
        let registration = targeted.registration

        let settled = Settled(
            applicationID: registration.applicationID,
            projectRoot: focus.root,
            projectName: focus.projectName,
            relativePath: focus.relativePath)
        let sameFile = settledBox.withLock { $0 } == settled

        guard let sink = sinkBox.withLock({ $0 }) else {
            settledBox.withLock { $0 = settled }
            return
        }

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
        let discipline = AmbientPlace.application(registration.applicationID).ability
        let units = CorpusCrawl.crawl(
            focusedPath: focus.absolutePath,
            root: focus.root,
            projectName: focus.projectName,
            corpus: corpus,
            index: index,
            applicationID: registration.applicationID,
            at: now,
            discipline: discipline)
        if units.isEmpty {
            // A claimed unit that produced nothing may be briefly unreadable;
            // do not lock the settle, so the next poll retries neighbours.
            let claimed = corpus.include.contains(
                (focus.relativePath as NSString).pathExtension)
            if !claimed {
                settledBox.withLock { $0 = settled }
            }
            return
        }

        let structureKey = Self.structureKey(for: units)
        let structureUnchanged = sameFile
            && lastStructureBox.withLock({ $0 }) == structureKey
        settledBox.withLock { $0 = settled }
        lastStructureBox.withLock { $0 = structureKey }

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
        if structureUnchanged && observations.isEmpty { return }

        // AWAITED, NOT FIRE-AND-FORGET. Two detached ingests have no ordering
        // guarantee, and a stale crawl landing second would pin an older hash
        // into the manifest — a file permanently "changed". The poller claim
        // already serializes crawls, so awaiting here serializes ingests free.
        await sink(structureUnchanged ? [] : units, observations, registration)
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
              let root = documentRoot(of: window, corpus: registration.schema),
              let title = string(window, kAXTitleAttribute)
        else { return nil }

        let projectName = (root as NSString).lastPathComponent
        let identity = registration.schema.workspaceIdentity
        let name: String?
        if let fromTitle = identity.focusedFileName(inTitle: title) {
            name = fromTitle
        } else if identity.rootSource == .documentFile || identity.focusedFileTitleSeparator.isEmpty {
            // Title unused: the document path itself is the focused file.
            var isDirectory: ObjCBool = false
            if let raw = string(window, kAXDocumentAttribute) {
                let path = URL(string: raw)?.path ?? raw
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    name = (path as NSString).lastPathComponent
                } else {
                    name = nil
                }
            } else {
                name = nil
            }
        } else {
            name = nil
        }
        guard let name else { return nil }
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

    /// The project folder the window is working in, from its `AXDocument`.
    ///
    /// ⚠️ `AXDocument` IS THE ACTIVE FILE, not the workspace — measured
    /// 2026-08-28 against a live editor with a source file open, and it is the
    /// opposite of what this code first assumed. No window attribute carries
    /// the workspace at all: `AXProxy` and `AXTitleUIElement` are nil, and the
    /// title carries only the project's NAME.
    ///
    /// So the root is found by climbing to the nearest ancestor holding a
    /// DECLARED marker. Without that climb the fallback below takes the folder
    /// the open file happens to sit in — which silently scopes "the project's
    /// style" to a handful of neighbours and names the project after a
    /// subdirectory.
    static func documentRoot(
        of window: AXUIElement, corpus: PluginCorpusSchema
    ) -> String? {
        guard let raw = string(window, kAXDocumentAttribute) else { return nil }
        let path = URL(string: raw)?.path ?? raw
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return nil }

        let identity = corpus.workspaceIdentity
        switch identity.rootSource {
        case .documentDirectory:
            return isDirectory.boolValue ? path : nil
        case .documentFile:
            guard !isDirectory.boolValue else { return nil }
            let containing = (path as NSString).deletingLastPathComponent
            guard !corpus.projectMarkers.isEmpty else { return containing }
            return projectRoot(containing: containing, markers: corpus.projectMarkers)
        case .documentAuto:
            if isDirectory.boolValue { return path }
            let containing = (path as NSString).deletingLastPathComponent
            guard !corpus.projectMarkers.isEmpty else { return containing }
            return projectRoot(containing: containing, markers: corpus.projectMarkers)
        }
    }

    /// The nearest ancestor of `directory` holding one of `markers`.
    ///
    /// A marker beginning with a dot matches as a SUFFIX, so `.xcodeproj`
    /// finds `Thing.xcodeproj`; any other name matches exactly. The climb is
    /// bounded because a path is data and a symlink loop is somebody else's
    /// directory tree.
    static func projectRoot(
        containing directory: String, markers: [String], maximumDepth: Int = 24
    ) -> String? {
        var current = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for _ in 0..<maximumDepth {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            let found = entries.contains { entry in
                markers.contains { marker in
                    marker.hasPrefix(".") && marker.count > 1 && !marker.contains("/")
                        ? entry.hasSuffix(marker) || entry == marker
                        : entry == marker
                }
            }
            if found { return current.path }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path == "/" { return nil }
            current = parent
        }
        return nil
    }

    /// `Project — Name` → `Name`, using the package's declared separator.
    /// Kept as the default identity's parse so existing tests that call this
    /// directly still describe that common editor shape.
    static func activeName(inTitle title: String) -> String? {
        PluginWorkspaceIdentitySchema.default.focusedFileName(inTitle: title)
    }

    /// A running corpus to sample when Mary's window (or system chrome) is
    /// frontmost — the same standing-workspace rule `CodeSurfacePollTarget`
    /// applies to the caret walk. Preferred ids are the last settled
    /// application, then the tracker lead; any running corpus is the last
    /// rung so a project Xcode already has open is understood before Lane A
    /// speaks.
    static func standingCorpus(
        preferredApplicationIDs: [String],
        support: CorpusSupport
    ) -> (registration: CorpusRegistration, pid: pid_t)? {
        func running(_ registration: CorpusRegistration) -> pid_t? {
            CorpusSupport.pid(of: registration)
        }
        for applicationID in preferredApplicationIDs {
            if let registration = support.registration(applicationID: applicationID),
               let pid = running(registration) {
                return (registration, pid)
            }
        }
        for registration in support.all {
            if let pid = running(registration) {
                return (registration, pid)
            }
        }
        return nil
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
