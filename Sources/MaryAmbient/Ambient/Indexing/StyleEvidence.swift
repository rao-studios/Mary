//
//  StyleEvidence.swift
//  MaryAmbient
//
//  WHAT: Where observations become convictions. One accrual policy, declared.
//  IN:   StyleProducer / StyleObservation
//  OUT:  Thread (durable profile). Splits: StyleEvidenceModels / +Freshness / +SayingSoByHand
//  PIN:  Counter-evidence decrements. Two policies for one fact is how confidence stops meaning anything.
//

import MaryFoundation
import Foundation
import os

/// Accumulates observations and answers with the tenets that have earned it. A plain
/// lock-boxed store rather than an actor: every operation is a fast synchronous tally.
public final class StyleEvidenceStore: @unchecked Sendable {

    public static let shared = StyleEvidenceStore()

    /// IDENTITY IS PART OF THE KEY.
    struct Key: Hashable {
        var scopeKind: StyleScopeKind
        var identity: String?
        var dimension: StyleDimension
    }

    let box = OSAllocatedUnfairLock<[Key: StyleEvidenceRow]>(initialState: [:])
    let policy: StyleAccrualPolicy
    /// Imported tenets are held separately: they are inert, they must survive
    /// alongside observed evidence without polluting its counts, and they are
    /// promoted only by this machine independently reaching the same value.
    let importedBox = OSAllocatedUnfairLock<[String: StyleTenet]>(initialState: [:])
    /// Assertions live apart from the tallies for the same reason imports do —
    /// mixing them in would make a statement of intent indistinguishable from
    /// evidence, and would let contrary observation demote it.
    let assertedBox = OSAllocatedUnfairLock<[String: StyleTenet]>(initialState: [:])
    /// Vetoed tenet keys. A veto is not a deletion: observation keeps
    /// counting underneath, so lifting the veto restores what the corpus
    /// actually says rather than an empty slot.
    let vetoedBox = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// The policy in force, so an inspector can show the thresholds a status
    /// was actually judged against rather than assuming the defaults.
    public var accrualPolicy: StyleAccrualPolicy { policy }

    public init(policy: StyleAccrualPolicy = .standard) {
        self.policy = policy
    }

    /// Record what ONE SOURCE says about one dimension. `source` is what the opinion belongs to
    /// — a unit key, normally.
    public func record(
        dimension: StyleDimension,
        value: StyleValue,
        weight: Int,
        scope: StyleScope,
        source: String,
        sourceHash: String = "",
        vocabulary: [String] = [],
        at now: Date = Date()
    ) {
        guard dimension != .unknown, weight > 0, !source.isEmpty else { return }
        let key = Key(
            scopeKind: scope.kind, identity: scope.identity, dimension: dimension)
        box.withLock { rows in
            var row = rows[key] ?? StyleEvidenceRow()
            // THE SAME BYTES ARE NOT NEW EVIDENCE. The crawl fires on focus, not on save, so an
            // unchanged file arrives here again every time the user looks at it.
            if let existing = row.contributions[source],
               !sourceHash.isEmpty, existing.sourceHash == sourceHash {
                return
            }
            let isNewSource = row.contributions[source] == nil
            row.contributions[source] = StyleContribution(
                value: value,
                weight: weight,
                vocabulary: dimension == .roleVocabulary ? vocabulary : [],
                sourceHash: sourceHash,
                at: now)
            // REAL EVIDENCE DISPLACES ITS SHARE OF THE RESTORED SNAPSHOT. Only a source NEW to the row
            // displaces: a file edited five times replaces its own contribution five times but owns
            // only one share of the snapshot.
            if isNewSource, !source.hasPrefix("\u{1F}") {
                for restoredKey in [Self.restoredSource, Self.restoredCounterSource] {
                    guard var blob = row.contributions[restoredKey],
                          blob.value == value else { continue }
                    blob.weight -= weight
                    row.contributions[restoredKey] = blob.weight > 0 ? blob : nil
                }
            }
            rows[key] = row
        }
    }

    /// Withdraw every opinion filed by sources under `prefix`.
    public func withdraw(sourcesWithPrefix prefix: String) {
        guard !prefix.isEmpty else { return }
        box.withLock { rows in
            for (key, var row) in rows {
                let before = row.contributions.count
                row.contributions = row.contributions.filter {
                    !$0.key.hasPrefix(prefix)
                }
                guard row.contributions.count != before else { continue }
                rows[key] = row.isEmpty ? nil : row
            }
        }
    }

    /// Counter-evidence: something disagreed with the value we believe. Used by the feedback
    /// loop when Mary's own edit is reverted or rewritten. Filed under its own source key so
    /// repeated disagreement about the same edit does not stack.
    public func recordDisagreement(
        dimension: StyleDimension,
        value: StyleValue,
        scope: StyleScope,
        source: String = "disagreement",
        at now: Date = Date()
    ) {
        guard dimension != .unknown else { return }
        let key = Key(
            scopeKind: scope.kind, identity: scope.identity, dimension: dimension)
        // Disagreement is support for "anything but this", which is what makes
        // it lower agreement without inventing an opinion about which
        // alternative is right.
        guard let other = dimension.values.first(where: { $0 != value }) else { return }
        box.withLock { rows in
            guard var row = rows[key] else { return }
            row.contributions["\u{1F}disagree|\(source)"] = StyleContribution(
                value: other, weight: 1, vocabulary: [], sourceHash: "", at: now)
            rows[key] = row
        }
    }

    /// Install imported tenets. They never join the observed tallies — an
    /// imported belief is a hypothesis about this user, not evidence about
    /// them.
    public func installImported(_ tenets: [StyleTenet]) {
        importedBox.withLock { store in
            for tenet in tenets where !tenet.provenance.isLocal {
                store[tenet.tenetKey] = tenet
            }
        }
    }

}
