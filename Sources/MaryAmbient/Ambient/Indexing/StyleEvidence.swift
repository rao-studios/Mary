//
//  StyleEvidence.swift
//  MaryAmbient
//
//  Where observations become convictions.
//
//  ONE ACCRUAL POLICY, DECLARED. The build this ports from had two for the
//  same type, disagreeing quietly: one seeded 0.75/0.25 and incremented
//  0.15/0.08, while the other seeded 0.85, incremented 0.1, and early-returned
//  on failure so refusals never persisted at all. Two policies for one fact is
//  how a confidence number stops meaning anything, so this one is a value you
//  can read, test, and change in a single place — in the spirit of
//  `TotemProjectionSchema` making memory a declaration rather than a side
//  effect.
//
//  COUNTER-EVIDENCE DECREMENTS. The observation-fact confidence this
//  descends from was a monotonic ratchet whose only downward pressure was a
//  45-day sweep, so an
//  idiom you have outgrown keeps its confidence until the code itself changes.
//  Here, disagreement is evidence too.
//

import MaryFoundation
import Foundation
import os

/// Accumulates observations and answers with the tenets that have earned it.
///
/// A plain lock-boxed store rather than an actor: every operation is a fast
/// synchronous tally, and the callers (a background crawl, a prompt provider)
/// want an answer without a suspension point.
public final class StyleEvidenceStore: @unchecked Sendable {

    public static let shared = StyleEvidenceStore()

    /// IDENTITY IS PART OF THE KEY. It used to be `(scopeKind, projectID,
    /// dimension)`, where `projectID` was nil for everything but `.project` —
    /// so two applications filing the same dimension shared one tally row, and
    /// `row.leader` returns nil on a tie, meaning an unrelated corpus could
    /// ERASE a genuine conviction rather than sitting beside it.
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

    /// Record what ONE SOURCE says about one dimension.
    ///
    /// `source` is what the opinion belongs to — a unit key, normally. Recording
    /// again from the same source REPLACES its previous opinion rather than
    /// adding to it, which is the fix for a real bug: `recordStyle` runs for
    /// every visited file on every crawl, so a file read ten times used to be
    /// counted ten times and support grew without bound as you moved around.
    ///
    /// `scope` is the scope this evidence is filed under — normally the
    /// dimension's widest, narrowed to a project when the evidence is about
    /// one repository's arrangement.
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
            // THE SAME BYTES ARE NOT NEW EVIDENCE. The crawl fires on focus,
            // not on save, so an unchanged file arrives here again every time
            // the user looks at it. Re-filing it would be harmless for the
            // TALLY — contributions replace by source — but it would refresh
            // the timestamp, and a file you merely keep glancing at would stay
            // permanently young while never being worked on. Declining the
            // write is what lets untouched work age out on schedule.
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
            // REAL EVIDENCE DISPLACES ITS SHARE OF THE RESTORED SNAPSHOT. The
            // restored blob already CONTAINS this file's opinion — it is a
            // rounded summary of every file that ever voted — so adding a real
            // re-observation on top of it double-counts, and the double-count
            // compounds: save → restore → edit ratcheted support upward on
            // every launch with no new files anywhere. Shrinking the
            // same-valued blob by the incoming weight keeps the total honest
            // while the live corpus gradually takes the snapshot's place.
            //
            // Only a source NEW to the row displaces: a file edited five times
            // replaces its own contribution five times but owns only one share
            // of the snapshot, and draining the blob per edit would spend the
            // other files' shares on it.
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

    /// Withdraw every opinion filed by sources under `prefix` — the unit was
    /// forgotten, and evidence should not outlive the thing it was read from.
    ///
    /// Prefix-matched because the crawl keys sources as
    /// `project|relativePath|dimension`: one file files one opinion per
    /// dimension, so forgetting the file means removing all of them. (The old
    /// whole-key variant could never match a key the crawl actually writes,
    /// and had no caller.)
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

    /// Counter-evidence: something disagreed with the value we believe. Used
    /// by the feedback loop when Mary's own edit is reverted or rewritten.
    ///
    /// Filed under its own source key so repeated disagreement about the same
    /// edit does not stack — it is one event, however many times it is noticed.
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
