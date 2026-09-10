//
//  CorpusObserver.swift
//  MaryPlugin
//
//  WHAT: What the user settled on, and the crawl it starts.
//  IN:   AX (root + title) / CorpusCrawl / CorpusStyleReader
//  OUT:  unit index / prompt neighbourhood / style (fresh edits only)
//  PIN:  Ambiguity resolves to nothing. Style only if mtime is this session
//        and not CodingAgentAuthorship.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse
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
    /// Last structure crawl identity — skip the sink if neighbours have not grown.
    private let lastStructureBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Rendered neighbourhood, ready for the prompt. Written after a crawl,
    /// cleared on deactivate — never the identity line.
    private let digestBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let poller = SinglePollerClaim()
    /// One crawl at a time. The claim owns the loop; this owns a single pass.
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

    /// Where a completed crawl goes. Injected so this file knows nothing about Thread.
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

    /// What the last completed poll settled on, for a caller that needs the
    /// project identity itself rather than a rendered line — the deposit
    /// subject, so retrieval can actually group by project rather than
    /// filing every coding turn under a nil group it can never search back.
    public var standingFocus: (
        applicationID: String, projectRoot: String, projectName: String, relativePath: String
    )? {
        settledBox.withLock { $0 }.map {
            ($0.applicationID, $0.projectRoot, $0.projectName, $0.relativePath)
        }
    }

    /// Neighbourhood digest after a crawl. Identity stays on `ambientLine`.
    public func promptContribution() -> String? {
        digestBox.withLock { $0 }
    }

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
        digestBox.withLock { $0 = nil }
    }

    /// Cadence. Slow: settling is human-scale. Viewing crawls structure; style needs a fresh edit.
    public static let pollSeconds: TimeInterval = 5

    /// Identity of a crawl's structure, so a view can retry neighbours
    /// without re-sending an unchanged neighbourhood.
    package static func structureKey(for units: [IndexedUnit]) -> String {
        units.map {
            "\($0.relativePath)|\($0.contentHash)|\($0.neighbours.sorted().joined(separator: ","))"
        }.sorted().joined(separator: ";")
    }

    /// Prompt-sized neighbourhood: declarations, related paths, focused file first.
    package static func neighborhoodDigest(
        units: [IndexedUnit], focusedPath: String, limit: Int = 12
    ) -> String {
        let focusedName = (focusedPath as NSString).lastPathComponent
        var lines = [
            "Project neighbourhood (from disk, around \(focusedName)):"
        ]
        for unit in units.prefix(limit) {
            var line = unit.relativePath
            let names = unit.declaredTypes.prefix(6)
            if !names.isEmpty {
                line += " — \(names.joined(separator: ", "))"
            }
            let related = unit.neighbours.prefix(4).map {
                ($0 as NSString).lastPathComponent
            }
            if !related.isEmpty {
                line += ". Related: \(related.joined(separator: ", "))"
            }
            lines.append(line)
        }
        if units.count > limit {
            lines.append("…and \(units.count - limit) more neighbouring files")
        }
        return lines.joined(separator: "\n")
    }

    /// Test seam: a standing neighbourhood without Accessibility.
    func adoptNeighborhoodForTests(
        place: AmbientPlace,
        projectName: String,
        relativePath: String,
        units: [IndexedUnit]
    ) {
        settledBox.withLock {
            $0 = Settled(
                applicationID: place.application ?? "",
                projectRoot: units.first?.subject.projectIdentity ?? "",
                projectName: projectName,
                relativePath: relativePath)
        }
        digestBox.withLock {
            $0 = Self.neighborhoodDigest(units: units, focusedPath: relativePath)
        }
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

        guard let hit = SurfacePollTarget.pairHit(
            claims: support.all,
            standingApplicationID: settledBox.withLock { $0 }?.applicationID),
              let registration = support.registration(
                applicationID: hit.applicationID),
              let focus = Self.focus(
                pid: hit.pid, registration: registration)
        else { return }

        let settled = Settled(
            applicationID: registration.applicationID,
            projectRoot: focus.root,
            projectName: focus.projectName,
            relativePath: focus.relativePath)
        let sameFile = settledBox.withLock { $0 } == settled

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
            // Claimed but empty may be briefly unreadable — do not lock settle.
            let claimed = corpus.include.contains(
                (focus.relativePath as NSString).pathExtension)
            if !claimed {
                settledBox.withLock { $0 = settled }
            }
            return
        }

        // Prompt sees this crawl now, not only Thread after the idle timer.
        digestBox.withLock {
            $0 = Self.neighborhoodDigest(
                units: units, focusedPath: focus.relativePath)
        }

        let structureKey = Self.structureKey(for: units)
        let structureUnchanged = sameFile
            && lastStructureBox.withLock({ $0 }) == structureKey
        settledBox.withLock { $0 = settled }
        lastStructureBox.withLock { $0 = structureKey }
        WorkspaceFocusTracker.shared.noteWork(
            place: AmbientPlace.application(registration.applicationID),
            processBundleID: SurfacePollTarget.runningProcesses()
                .first { $0.pid == hit.pid }?.bundleID)

        guard let sink = sinkBox.withLock({ $0 }) else { return }

        // Style only from a fresh edit of the focused file, not its neighbours.
        var observations: [StyleObservation] = []
        if Self.isFreshEdit(focus.absolutePath, at: now),
           let read = CorpusCrawl.read(
            relativePath: focus.relativePath, root: focus.root, corpus: corpus) {
            observations = CorpusStyleReader.observe(
                text: read.text, declaredTypes: read.declaredNames, corpus: corpus)
        }
        if structureUnchanged && observations.isEmpty { return }

        // Awaited, not fire-and-forget. A stale ingest second would pin an older hash.
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

    /// Project folder from `AXDocument`. PIN: that attribute is the active file,
    /// not the workspace — climb to the nearest ancestor holding a declared marker.
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

    /// Nearest ancestor holding a marker. Dotted markers match as suffix
    /// (`.xcodeproj` finds `Thing.xcodeproj`); other names match exactly. Climb is bounded.
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

    /// `Project — Name` → `Name` via the package's declared separator.
    static func activeName(inTitle title: String) -> String? {
        PluginWorkspaceIdentitySchema.default.focusedFileName(inTitle: title)
    }

    /// A name is not a path. Exactly one matching unit, with or without extension.
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
        if CodingAgentAuthorship.contains(absolutePath) { return false }
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
