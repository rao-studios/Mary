//
//  StyleEvidence+SayingSoByHand.swift
//

import MaryFoundation
import Foundation
import os

extension StyleEvidenceStore {

    // MARK: - Saying so by hand

    /// State a tenet outright. It renders from the next turn, is never
    /// demoted, and outranks whatever the corpus says on the same dimension.
    ///
    /// The value comes from the CLOSED vocabulary — there is no free-text
    /// path, because free text reaching a model is exactly what the trust
    /// model forbids, and it would forbid it no less for having been typed
    /// here than for having arrived in someone else's profile.
    @discardableResult
    public func assert(
        dimension: StyleDimension,
        value: StyleValue,
        scope: StyleScope,
        vocabulary: [String] = [],
        at now: Date = Date()
    ) -> StyleTenet? {
        let tenet = StyleTenet(
            dimension: dimension,
            value: value,
            scope: scope,
            support: 0,
            counter: 0,
            confidence: 1,
            status: .verified,
            provenance: .asserted,
            lastObservedAt: now,
            vocabulary: vocabulary)
        guard tenet.isMeaningful else { return nil }
        assertedBox.withLock { $0[tenet.tenetKey] = tenet }
        // Asserting something un-vetoes it; the two gestures are opposites and
        // holding both would be a state nobody could reason about.
        vetoedBox.withLock { $0.remove(tenet.tenetKey) }
        return tenet
    }

    public func retractAssertion(tenetKey: String) {
        assertedBox.withLock { $0[tenetKey] = nil }
    }

    public func assertions() -> [StyleTenet] {
        assertedBox.withLock { $0 }.values.sorted { $0.tenetKey < $1.tenetKey }
    }

    /// Silence a tenet without stating its opposite. Observation continues
    /// underneath, so lifting the veto shows what the corpus actually says
    /// rather than a hole.
    public func veto(tenetKey: String) {
        vetoedBox.withLock { _ = $0.insert(tenetKey) }
        assertedBox.withLock { $0[tenetKey] = nil }
    }

    public func liftVeto(tenetKey: String) {
        vetoedBox.withLock { $0.remove(tenetKey) }
    }

    public func vetoed() -> Set<String> { vetoedBox.withLock { $0 } }

    public func isVetoed(_ tenetKey: String) -> Bool {
        vetoedBox.withLock { $0.contains(tenetKey) }
    }

    /// Where an assertion and the corpus disagree on the same dimension.
    ///
    /// Reported rather than resolved. The assertion wins in the brief, but a
    /// person telling Mary one thing while their code says another is the
    /// single most interesting row in the whole profile, and hiding it would
    /// throw away the reason for having both.
    public func conflicts(at now: Date = Date()) -> [(asserted: StyleTenet, observed: StyleTenet)] {
        conflicts(observed: observedTenets(at: now))
    }

    /// The same answer from an `observedTenets` pass the caller already has.
    ///
    /// Recomputing it is not free — every row re-weights every contribution —
    /// and the Corpus pane used to ask for it three times a second through
    /// `tenets`, `observedTenets` and `conflicts`, then usually throw all three
    /// away as unchanged.
    public func conflicts(
        observed: [StyleTenet]
    ) -> [(asserted: StyleTenet, observed: StyleTenet)] {
        let observedByKey = Dictionary(
            observed.map { ($0.tenetKey, $0) },
            uniquingKeysWith: { first, _ in first })
        return assertions().compactMap { asserted in
            guard let observed = observedByKey[asserted.tenetKey],
                  observed.value != asserted.value,
                  observed.isMeaningful
            else { return nil }
            return (asserted, observed)
        }
    }

    /// Every tenet the store believes, with assertions winning.
    ///
    /// Precedence: asserted > observed > imported, one row per dimension. An
    /// imported tenet is emitted (it is inspectable, and `isRenderable`
    /// already refuses it) but only while nothing local covers that dimension.
    /// A vetoed key is dropped from the answer entirely while the tallies
    /// underneath keep running.
    ///
    /// `observedTenets(at:)` is the unmerged view, which is what
    /// `conflicts(at:)` and the inspector need — the merge is a presentation
    /// decision, not the truth.
    public func tenets(at now: Date = Date()) -> [StyleTenet] {
        tenets(observed: observedTenets(at: now))
    }

    /// As above, from a pass the caller already has. Same reasoning as
    /// `conflicts(observed:)`.
    public func tenets(observed: [StyleTenet]) -> [StyleTenet] {
        let asserted = assertedBox.withLock { $0 }
        let vetoed = vetoedBox.withLock { $0 }
        var byKey: [String: StyleTenet] = [:]
        for tenet in observed { byKey[tenet.tenetKey] = tenet }
        for (key, tenet) in asserted { byKey[key] = tenet }

        let imported = importedBox.withLock { $0 }.values
            .filter { byKey[$0.tenetKey] == nil }
        return (Array(byKey.values) + imported)
            .filter { !vetoed.contains($0.tenetKey) }
            .sorted { $0.tenetKey < $1.tenetKey }
    }

    /// What the corpus alone says, before assertions override anything.
    ///
    /// Age is handled by ONE mechanism now: the half-life. A contribution
    /// whose recency weight has fallen under `StyleRecency.decayFloor` stops
    /// counting in `tallies`, so a row that has entirely faded produces no
    /// leader and emits no tenet at all. `evictDecayed` then reclaims the row
    /// itself. There is no separate stale stage, no horizon and no work clock —
    /// they were four answers to one question.
    public func observedTenets(at now: Date = Date()) -> [StyleTenet] {
        let rows = box.withLock { $0 }
        var observed: [StyleTenet] = []

        for (key, row) in rows where !row.isEmpty {
            let scope = StyleScope(kind: key.scopeKind, identity: key.identity)
            if key.dimension == .roleVocabulary {
                let totals = row.vocabularyTallies(at: now)
                let words = totals
                    .filter { $0.value >= 1.5 }
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .prefix(8)
                    .map(\.key)
                guard !words.isEmpty else { continue }
                // Support counts only the words that cleared the bar — summing
                // the sub-threshold tail let two files sharing one suffix out
                // of twenty read as support 21, confidence 1.0.
                let support = Int(totals.values.filter { $0 >= 1.5 }.reduce(0, +).rounded())
                let sources = row.sources(of: .unknown, at: now)
                observed.append(StyleTenet(
                    dimension: .roleVocabulary,
                    value: .unknown,
                    scope: scope,
                    support: support,
                    counter: 0,
                    confidence: policy.confidence(support: support, counter: 0),
                    status: policy.status(
                        support: support, counter: 0, sources: sources,
                        previous: row.status),
                    provenance: .observed,
                    lastObservedAt: row.lastObservedAt,
                    vocabulary: words))
                continue
            }

            guard let leader = row.leader(at: now) else { continue }
            observed.append(StyleTenet(
                dimension: key.dimension,
                value: leader.value,
                scope: scope,
                support: leader.support,
                counter: leader.counter,
                confidence: policy.confidence(support: leader.support, counter: leader.counter),
                status: policy.status(
                    support: leader.support, counter: leader.counter,
                    sources: row.sources(of: leader.value, at: now),
                    previous: row.status),
                provenance: .observed,
                lastObservedAt: row.lastObservedAt))
        }

        // Observed ONLY. Imports and assertions are merged in `tenets(at:)`;
        // folding them in here would make `conflicts(at:)` compare an
        // assertion against itself.
        return observed.sorted { $0.tenetKey < $1.tenetKey }
    }

}
