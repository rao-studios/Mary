//
//  MaryRuntime+Corpus.swift
//  MaryRuntime
//
//  WHAT: Corpus writes — manifest, evidence, ledger, Thread must agree.
//  IN:   CorpusObserver units/observations
//  OUT:  unitIndexer, StyleEvidenceStore, ThreadContextStore, UnitIndexLedger
//  PIN:  Ability-keyed profiles, never application-keyed. Observer is injected.
//

import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import Foundation
import os

extension MaryRuntime {

    /// Write the style profile, coalesced. Latest wins — one settle, not one write per unit.
    static func requestStyleProfileSave(after delay: TimeInterval = 5) {
        styleSaveBox.withLock { task in
            task?.cancel()
            task = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Sweep before write: persist what the corpus believes after ageing.
                refreshStyleCorpus()
                await persistStyleProfile()
            }
        }
    }

    /// Publish current corpus, report changes, drop quiet subjects. Same coalesced tick.
    static func refreshStyleCorpus(at now: Date = Date()) {
        let store = StyleEvidenceStore.shared
        store.publish(at: now)
        for evicted in store.evictDecayed(at: now) {
            UnitIndexLedger.shared.noteEviction(subject: evicted, at: now)
        }
    }

    static func persistStyleProfile() async {
        let store = StyleEvidenceStore.shared
        let now = Date()
        for producer in StyleProducerRegistry.shared.all() {
            let subject = producer.ability.rawValue
            // Unfiltered by veto, locals only — persistence is not rendering.
            let tenets = store.persistableTenets(
                forSubject: subject,
                applications: producer.applications,
                languages: producer.languages,
                at: now)
            // Empty document is written — that is what makes a forget durable.
            await threadContext.depositStyleProfile(
                tenets,
                vetoedTenetKeys: Array(store.vetoed()),
                applications: producer.applications,
                subject: subject,
                at: now)
        }
    }

}

extension MaryRuntime {

    /// Point CorpusObserver at its switch and stores. Observer does not know Thread.
    package static func installCorpusPipeline() {
        let observer = CorpusObserver.shared

        // Per-poll read, not captured once — switching off takes effect next poll.
        observer.setEnabled { corpusIndexingEnabledBox.withLock { $0 } }

        observer.setSink { units, observations, registration in
            if let first = units.first {
                UnitIndexLedger.shared.noteCrawl(
                    projectName: first.projectName,
                    focusedPath: first.relativePath,
                    unitCount: units.count)
            }
            for unit in units {
                await unitIndexer.ingest(unit)
            }
            guard !observations.isEmpty else { return }
            // Ability-keyed: a second editor realizing the same craft must read this profile.
            let place = AmbientPlace.application(registration.applicationID)
            guard let ability = place.ability else { return }
            let source = "\(registration.applicationID)|\(registration.schema.notation)"
            for observation in observations {
                StyleEvidenceStore.shared.record(
                    dimension: observation.dimension,
                    value: observation.value,
                    weight: observation.weight,
                    scope: StyleScope(kind: .ability, identity: ability.rawValue),
                    source: source,
                    vocabulary: observation.vocabulary)
            }
            requestStyleProfileSave()
        }
    }

    /// Mirrors the config flag so the observer's per-poll read is a lock, not a Granite hop.
    static let corpusIndexingEnabledBox = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Live switch. Lock stays internal — a caller holding it could stall a poll.
    package static var corpusIndexingIsEnabled: Bool {
        corpusIndexingEnabledBox.withLock { $0 }
    }

    package static func applyCorpusIndexing(enabled: Bool) {
        corpusIndexingEnabledBox.withLock { $0 = enabled }
    }



    /// Pin corrected labels. Manifest first, then Thread — coordinator owns the hash gate.
    package static func pinUnitLabels(
        _ labels: [String], unitKey: String, path: String,
        projectID: String, projectName: String
    ) async -> String {
        await unitIndexer.pinLabels(labels, path: path, projectID: projectID)
        UnitIndexLedger.shared.notePinnedLabels(labels, forUnit: unitKey)
        guard let manifest = await unitIndexer.manifest(forProject: projectID) else {
            return "Nothing to pin — that file has not been indexed yet."
        }
        await threadContext.persistUnitManifest(
            manifest, projectID: projectID, projectName: projectName)
        return labels.isEmpty
            ? "Unpinned. The next summary decides its own labels again."
            : "Pinned. These labels survive every re-index from now on."
    }

    /// Forget a unit: manifest row, ledger row, Thread document.
    package static func forgetUnit(
        unitKey: String, path: String, projectID: String, projectName: String
    ) async -> String {
        await unitIndexer.forget(path: path, projectID: projectID)
        // Style evidence must not outlive the unit. Crawl keys `project|relativePath|dimension`.
        StyleEvidenceStore.shared.withdraw(sourcesWithPrefix: "\(projectName)|\(path)|")
        let removed = await threadContext.forgetUnit(unitKey: unitKey)
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await threadContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteForgotten(unitKey: unitKey)
        return removed
            ? "Forgotten, and removed from the thread."
            : "Forgotten locally. The thread copy could not be reached — it will go on the next clear."
    }

    /// Clear a unit's hash gate so the next visit re-reads it.
    package static func reindexUnit(
        path: String, projectID: String, projectName: String
    ) async -> String {
        let cleared = await unitIndexer.invalidate(path: path, projectID: projectID)
        guard cleared else { return "That file was not in the index." }
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await threadContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteInvalidated(
            projectName: projectName, subject: path)
        return "Cleared. It re-indexes next time you settle on it."
    }

    static func reindexProject(projectID: String, projectName: String) async -> String {
        let count = await unitIndexer.invalidate(projectID: projectID)
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await threadContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteInvalidated(
            projectName: projectName, subject: "the whole project")
        return "Cleared \(count) files. They re-index as you visit them."
    }

    /// State a tenet by hand. Renders next turn; corpus keeps counting so disagreement stays visible.
    package static func assertTenet(
        dimension: StyleDimension, value: StyleValue, scope: StyleScope,
        vocabulary: [String] = []
    ) async -> String {
        guard StyleEvidenceStore.shared.assert(
            dimension: dimension, value: value, scope: scope, vocabulary: vocabulary
        ) != nil else {
            return "That is not a combination Mary has a sentence for."
        }
        await persistStyleProfile()
        return "Noted. Mary will work this way from your next request."
    }

    package static func retractTenet(tenetKey: String) async -> String {
        StyleEvidenceStore.shared.retractAssertion(tenetKey: tenetKey)
        await persistStyleProfile()
        return "Retracted. What your code shows decides this again."
    }

    package static func vetoTenet(tenetKey: String) async -> String {
        StyleEvidenceStore.shared.veto(tenetKey: tenetKey)
        await persistStyleProfile()
        return "Silenced. Mary keeps watching but will not act on it."
    }

    package static func liftTenetVeto(tenetKey: String) async -> String {
        StyleEvidenceStore.shared.liftVeto(tenetKey: tenetKey)
        await persistStyleProfile()
        return "Unsilenced."
    }

    /// Drop inferred corpus; keep what was stated by hand.
    static func forgetObservedStyle() async -> String {
        StyleEvidenceStore.shared.resetObservations()
        await persistStyleProfile()
        return "Cleared what Mary inferred. What you stated by hand is untouched."
    }

}
