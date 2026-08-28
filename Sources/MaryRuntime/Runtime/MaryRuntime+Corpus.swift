//
//  MaryRuntime+Corpus.swift
//  MaryRuntime
//
//  THE CORPUS'S WRITES, in one place.
//
//  Each of these touches stores that must agree: the coordinator's manifest
//  (the hash gate), the evidence store (what the corpus believes), the ledger
//  (what the pane shows) and Totem (the durable copy). Doing them inline from
//  a view would be several chances to update all but one.
//

import MaryAdapters
import MaryAmbient
import MaryBrain
import MaryFoundation
import Foundation
import os

extension MaryRuntime {

    /// Write the style profile out, coalesced.
    ///
    /// A crawl publishes up to two dozen units and every one of them can move
    /// a tally, so persisting per unit would be two dozen Totem writes for one
    /// settle. This collapses them the way `AmbientDigestRefresher` collapses
    /// its refreshes: latest wins, never stack.
    static func requestStyleProfileSave(after delay: TimeInterval = 5) {
        styleSaveBox.withLock { task in
            task?.cancel()
            task = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Sweep BEFORE writing: what gets persisted should be what the
                // corpus believes after ageing, not before it.
                refreshStyleCorpus()
                await persistStyleProfile()
            }
        }
    }

    /// ONE DOCUMENT PER SUBJECT. This used to read the entire store and label
    /// all of it `subject: xcode` — correct only while Xcode was the sole
    /// producer, and a silent overwrite the moment anything else filed
    /// evidence. Each application's profile now carries its own tenets plus
    /// the broader rungs its work sits under (its Ability, its languages),
    /// which is exactly what the export format is for.
    /// Publish what the corpus now says, report what changed, and drop what
    /// has gone quiet.
    ///
    /// Runs on the same coalesced tick as the profile write, so a settle does
    /// one sweep rather than one per unit.
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
            // An empty document is WRITTEN, never skipped: it is what makes a
            // forget durable.
            await totemContext.depositStyleProfile(
                tenets,
                vetoedTenetKeys: Array(store.vetoed()),
                applications: producer.applications,
                subject: subject,
                at: now)
        }
    }

}

extension MaryRuntime {

    /// Point the corpus observer at its switch and its stores.
    ///
    /// THE OBSERVER KNOWS NOTHING ABOUT ANY OF THIS. It reads a window, walks
    /// a project and produces units and observations; where they go is
    /// injected here, which is what keeps MaryAdapters free of Totem and the
    /// evidence store, and what lets a test hand it an array instead.
    package static func installCorpusPipeline() {
        let observer = CorpusObserver.shared

        // READ PER POLL, not captured once: a person switching indexing off
        // expects the next poll to stop, not the next launch.
        observer.setEnabled { corpusIndexingEnabledBox.withLock { $0 } }

        observer.setSink { units, observations, registration in
            for unit in units {
                await unitIndexer.ingest(unit)
            }
            guard !observations.isEmpty else { return }
            // ABILITY-KEYED, NEVER APPLICATION-KEYED. Learning how somebody
            // codes in one editor has to teach Mary how they code in the
            // next one, and a profile filed under the application cannot be
            // read by a second application realizing the same craft.
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

    /// Mirrors the config flag so the observer's per-poll read is a lock and
    /// not a hop into Granite from a background task.
    static let corpusIndexingEnabledBox = OSAllocatedUnfairLock<Bool>(initialState: true)

    package static func applyCorpusIndexing(enabled: Bool) {
        corpusIndexingEnabledBox.withLock { $0 = enabled }
    }



    /// Pin corrected labels to a unit.
    ///
    /// The manifest is written first and then re-persisted, because the
    /// coordinator owns it — writing Totem first would leave the durable copy
    /// ahead of the gate that decides whether the next crawl even looks.
    package static func pinUnitLabels(
        _ labels: [String], unitKey: String, path: String,
        projectID: String, projectName: String
    ) async -> String {
        await unitIndexer.pinLabels(labels, path: path, projectID: projectID)
        UnitIndexLedger.shared.notePinnedLabels(labels, forUnit: unitKey)
        guard let manifest = await unitIndexer.manifest(forProject: projectID) else {
            return "Nothing to pin — that file has not been indexed yet."
        }
        await totemContext.persistUnitManifest(
            manifest, projectID: projectID, projectName: projectName)
        return labels.isEmpty
            ? "Unpinned. The next summary decides its own labels again."
            : "Pinned. These labels survive every re-index from now on."
    }

    /// Forget a unit: its manifest row, its ledger row, and its Totem document.
    package static func forgetUnit(
        unitKey: String, path: String, projectID: String, projectName: String
    ) async -> String {
        await unitIndexer.forget(path: path, projectID: projectID)
        // Style evidence must not outlive the unit it was read from — the
        // crawl keys sources as `project|relativePath|dimension`, so the
        // prefix removes the file's one opinion on every dimension at once.
        StyleEvidenceStore.shared.withdraw(sourcesWithPrefix: "\(projectName)|\(path)|")
        let removed = await totemContext.forgetUnit(unitKey: unitKey)
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await totemContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteForgotten(unitKey: unitKey)
        return removed
            ? "Forgotten, and removed from the totem."
            : "Forgotten locally. The totem copy could not be reached — it will go on the next clear."
    }

    /// Clear a unit's hash gate so the next visit re-reads it.
    package static func reindexUnit(
        path: String, projectID: String, projectName: String
    ) async -> String {
        let cleared = await unitIndexer.invalidate(path: path, projectID: projectID)
        guard cleared else { return "That file was not in the index." }
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await totemContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteInvalidated(
            projectName: projectName, subject: path)
        return "Cleared. It re-indexes next time you settle on it."
    }

    static func reindexProject(projectID: String, projectName: String) async -> String {
        let count = await unitIndexer.invalidate(projectID: projectID)
        if let manifest = await unitIndexer.manifest(forProject: projectID) {
            await totemContext.persistUnitManifest(
                manifest, projectID: projectID, projectName: projectName)
        }
        UnitIndexLedger.shared.noteInvalidated(
            projectName: projectName, subject: "the whole project")
        return "Cleared \(count) files. They re-index as you visit them."
    }

    /// State a tenet by hand. It renders from the next turn and outranks the
    /// corpus; the corpus keeps counting so the disagreement stays visible.
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

    /// Drop everything learned from the corpus, keeping what was said by hand.
    static func forgetObservedStyle() async -> String {
        StyleEvidenceStore.shared.resetObservations()
        await persistStyleProfile()
        return "Cleared what Mary inferred. What you stated by hand is untouched."
    }

}
