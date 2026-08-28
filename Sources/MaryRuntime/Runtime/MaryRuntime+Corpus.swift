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
}
