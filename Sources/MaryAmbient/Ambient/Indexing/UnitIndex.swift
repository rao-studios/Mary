//
//  UnitIndex.swift
//  MaryAmbient
//
//  The durable half of ambient code indexing: one card per file the user has
//  settled on, plus its neighbourhood. `AmbientProjectSnapshot` (this file's
//  older sibling) answers "what shape is this project"; a unit answers "what
//  is this ONE thing, and what does it touch."
//
//  WHY A UNIT AND NOT A BIGGER PROJECT DOCUMENT. The project snapshot is a
//  single upserted document per project, so every re-index rewrites the whole
//  thing. That is right for a binder outline and wrong for code: moving from
//  one file to another would erase what was learned about the first. A unit is
//  addressed per file, so a neighbourhood accumulates instead of replacing.
//
//  THE CONTENT HASH IS THE WHOLE EFFICIENCY STORY. It gates the one expensive
//  step — annotation costs a model round — so an unchanged file is never
//  re-read, re-annotated, or re-deposited. Without it, returning to a file you
//  are working in would re-summarize it every time the idle timer fired.
//
//  This layer is deliberately application-agnostic. It names no language, no
//  editor, and no extractor: Xcode supplies units today, and a Scrivener
//  chapter or a Keynote deck is the same shape with a different producer.
//

import CryptoKit
import Foundation
/// Delays unit indexing until the user has stopped moving, annotates once per
/// file revision, and publishes.
///
/// Shaped after `AmbientProjectIndexingCoordinator` — per-key cancellable
/// task, idle debounce, fingerprint dedupe, injected sink, `flush()` seam —
/// with two additions it does not need: a durable manifest, and a serialized
/// annotation step.
public actor AmbientUnitIndexingCoordinator: AmbientUnitIndexSink {

    /// The manifest rides along with the unit, so the sink persists what the
    /// coordinator actually holds rather than maintaining a second copy that
    /// can drift from it.
    public typealias IndexSink = @Sendable (IndexedUnit, UnitIndexManifest) async -> Void

    private let idleNanoseconds: UInt64
    private let indexSink: IndexSink
    private let ledger: UnitIndexLedger?
    private var annotator: (any UnitAnnotating)?
    private var pending: [String: IndexedUnit] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// projectID -> manifest.
    private var manifests: [String: UnitIndexManifest] = [:]
    /// Fetches a project's durable manifest on the FIRST sight of a projectID
    /// this session. Boot restores only the configured projects; a repo the
    /// user opens without registering it would otherwise lose its manifest on
    /// every launch — every file "first sighting" again, every file
    /// re-annotated, and no style on the first edit of anything.
    private var manifestLoader: (@Sendable (String) async -> UnitIndexManifest?)?
    /// Projects already asked for, so one with no durable manifest is asked
    /// exactly once rather than on every crawl.
    private var manifestLoadAttempted: Set<String> = []
    /// The tail of the annotation chain. One annotation runs at a time: a
    /// crawl produces two dozen units at once, and a background annotator that
    /// fanned out would contend with the turn path for the same engine.
    private var annotationChain: Task<Void, Never>?

    public init(
        idleFor: TimeInterval = 12,
        annotator: (any UnitAnnotating)? = nil,
        ledger: UnitIndexLedger? = .shared,
        indexSink: @escaping IndexSink
    ) {
        idleNanoseconds = UInt64(max(0.1, idleFor) * 1_000_000_000)
        self.annotator = annotator
        self.ledger = ledger
        self.indexSink = indexSink
    }

    deinit {
        for task in tasks.values { task.cancel() }
        annotationChain?.cancel()
    }

    public func setAnnotator(_ annotator: (any UnitAnnotating)?) {
        self.annotator = annotator
    }

    /// A new loader may know projects the old one did not (a sign-in), so the
    /// attempted set starts over with it.
    public func setManifestLoader(
        _ loader: (@Sendable (String) async -> UnitIndexManifest?)?
    ) {
        manifestLoader = loader
        manifestLoadAttempted = []
    }

    private func loadManifestIfUnknown(projectID: String) async {
        guard manifests[projectID] == nil,
              !manifestLoadAttempted.contains(projectID),
              let loader = manifestLoader else { return }
        manifestLoadAttempted.insert(projectID)
        guard var loaded = await loader(projectID), loaded.isReadable else { return }
        // The await above is a reentrancy window: an ingest may have landed
        // fresher entries while the load was in flight, and fresher wins.
        if let current = manifests[projectID] {
            loaded.entries.merge(current.entries) { _, current in current }
        }
        manifests[projectID] = loaded
    }

    public func ingest(_ unit: IndexedUnit) async {
        guard let projectID = unit.projectID, !projectID.isEmpty,
              !unit.relativePath.isEmpty else { return }
        await loadManifestIfUnknown(projectID: projectID)
        // Already indexed at this exact revision — the gate that makes
        // re-focusing a file you are working in free. Recorded rather than
        // silent: a skipped row is what makes the gate observable, and it is
        // as informative as an indexed one.
        if manifests[projectID]?.entries[unit.relativePath]?.contentHash == unit.contentHash {
            ledger?.noteSkipped(
                projectName: unit.projectName,
                relativePath: unit.relativePath,
                at: unit.capturedAt)
            return
        }

        let key = "\(projectID)\u{1F}\(unit.relativePath)"
        pending[key] = unit
        tasks[key]?.cancel()
        let wait = idleNanoseconds
        tasks[key] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: wait) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flush(key: key)
        }
    }

    public func reset() {
        for task in tasks.values { task.cancel() }
        annotationChain?.cancel()
        annotationChain = nil
        pending = [:]
        tasks = [:]
        manifests = [:]
        manifestLoadAttempted = []
    }

    /// Test and shutdown seam: publish every stable candidate without waiting
    /// out the idle timer.
    public func flush() async {
        for key in pending.keys.sorted() {
            await flush(key: key)
        }
        await drainAnnotations()
    }

    /// Await the annotation chain. Tests need this because publication happens
    /// on the far side of it.
    public func drainAnnotations() async {
        await annotationChain?.value
    }

    /// Rehydrate a project's catalogue after relaunch. A manifest from a newer
    /// format is refused rather than half-read.
    public func restore(_ manifest: UnitIndexManifest, projectID: String) {
        guard manifest.isReadable else { return }
        manifests[projectID] = manifest
        manifestLoadAttempted.insert(projectID)
    }

    public func manifest(forProject projectID: String) -> UnitIndexManifest? {
        manifests[projectID]
    }

    public func knownContentHash(relativePath: String, projectID: String) async -> String? {
        await loadManifestIfUnknown(projectID: projectID)
        return manifests[projectID]?.entries[relativePath]?.contentHash
    }

    public func projectIDs() -> [String] { manifests.keys.sorted() }

    // MARK: - Manual control

    /// Clear one unit's hash gate so the next visit re-reads it.
    ///
    /// `reset()` was the only way to do this and it nukes every project, which
    /// makes "re-index this one file" impossible — the exact operation you
    /// need after correcting something and wanting to see the correction land.
    @discardableResult
    public func invalidate(path: String, projectID: String) -> Bool {
        guard manifests[projectID]?.entries.removeValue(forKey: path) != nil else {
            return false
        }
        return true
    }

    @discardableResult
    public func invalidate(projectID: String) -> Int {
        let count = manifests[projectID]?.entries.count ?? 0
        manifests[projectID]?.entries = [:]
        return count
    }

    /// Pin labels for one unit. From here on the annotator's labels are
    /// discarded for it and these are used instead; the précis still refreshes
    /// on the next revision, so the card stays current without losing the
    /// correction.
    public func pinLabels(
        _ labels: [String], path: String, projectID: String
    ) {
        guard var manifest = manifests[projectID],
              var entry = manifest.entries[path] else { return }
        let cleaned = Array(Set(labels.filter { !$0.isEmpty })).sorted()
        entry.pinnedLabels = cleaned.isEmpty ? nil : cleaned
        if !cleaned.isEmpty {
            entry.labels = cleaned
            entry.annotation = .pinned
        }
        manifest.entries[path] = entry
        manifests[projectID] = manifest
    }

    public func pinnedLabels(path: String, projectID: String) -> [String]? {
        manifests[projectID]?.entries[path]?.pinnedLabels
    }

    /// Drop a unit entirely — its hash gate and its manifest row. The caller
    /// removes the Totem document; this is the local half.
    public func forget(path: String, projectID: String) {
        manifests[projectID]?.entries[path] = nil
    }

    // MARK: - The pipeline

    private func flush(key: String) async {
        tasks[key] = nil
        guard let unit = pending.removeValue(forKey: key),
              let projectID = unit.projectID else { return }
        if manifests[projectID]?.entries[unit.relativePath]?.contentHash == unit.contentHash {
            return
        }
        // Record BEFORE annotating. The manifest's job is to stop repeated
        // work, and an entry written only on the far side of a slow annotation
        // would let the next idle tick queue the same unit again.
        let pinned = manifests[projectID]?.entries[unit.relativePath]?.pinnedLabels
        var manifest = manifests[projectID] ?? UnitIndexManifest()
        manifest.entries[unit.relativePath] = .init(
            contentHash: unit.contentHash,
            labels: pinned ?? [],
            indexedAt: unit.capturedAt,
            pinnedLabels: pinned,
            annotation: .pending)
        manifests[projectID] = manifest
        ledger?.noteIndexed(unit)

        enqueueAnnotation { [weak self] in
            guard let self else { return }
            let result = await self.annotated(unit, pinnedLabels: pinned)
            await self.publish(result.unit, outcome: result.outcome, projectID: projectID)
        }
    }

    /// Annotate, and say WHY the result looks the way it does. The outcome is
    /// returned rather than inferred from an empty label list, which is what
    /// made "not annotated", "no annotator" and "refused" indistinguishable.
    private func annotated(
        _ unit: IndexedUnit, pinnedLabels: [String]?
    ) async -> (unit: IndexedUnit, outcome: UnitAnnotationOutcome) {
        guard let annotator else { return (unit, .noAnnotator) }
        let annotation = await annotator.annotate(.init(
            projectName: unit.projectName,
            relativePath: unit.relativePath,
            declaredTypes: unit.declaredTypes,
            relations: unit.relations,
            apiHeaders: unit.apiHeaders,
            doc: unit.doc))
        guard let annotation, !annotation.isEmpty else {
            return (unit, annotator.refusesToAnnotate ? .refusedExclusiveEngine : .failed)
        }
        var annotated = unit
        // A hand correction outranks the model, every time, for this unit —
        // while the précis is taken fresh, so pinning a label does not freeze
        // the rest of the card.
        if let pinnedLabels, !pinnedLabels.isEmpty {
            annotated.annotation = UnitAnnotation(
                precis: annotation.precis, labels: pinnedLabels)
            return (annotated, .pinned)
        }
        annotated.annotation = annotation
        return (annotated, .ran)
    }

    private func publish(
        _ unit: IndexedUnit, outcome: UnitAnnotationOutcome, projectID: String
    ) async {
        if let labels = unit.annotation?.labels, !labels.isEmpty {
            manifests[projectID]?.entries[unit.relativePath]?.labels = labels
        }
        manifests[projectID]?.entries[unit.relativePath]?.annotation = outcome
        ledger?.noteAnnotation(
            outcome,
            precis: unit.annotation?.precis,
            labels: unit.annotation?.labels ?? [],
            forUnit: unit.unitKey)
        // THE MANIFEST TRAVELS WITH THE UNIT. It used to be rebuilt
        // independently on the far side of the sink, so a hand-edited label
        // updated one copy and not the other and the two drifted apart with
        // nothing to notice.
        await indexSink(unit, manifests[projectID] ?? UnitIndexManifest())
    }

    /// Chain rather than fan out, mirroring the follow-up chain in the brain:
    /// each unit's annotation waits for the previous one to finish, so a
    /// twenty-four file crawl trickles instead of arriving all at once.
    private func enqueueAnnotation(_ work: @escaping @Sendable () async -> Void) {
        let previous = annotationChain
        annotationChain = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}
