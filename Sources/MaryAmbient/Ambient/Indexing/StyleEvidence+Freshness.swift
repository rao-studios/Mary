//
//  StyleEvidence+Freshness.swift
//

import MaryFoundation
import Foundation
import os

extension StyleEvidenceStore {

    // MARK: - Freshness

    /// Latch each row's published status.
    ///
    /// SMALL, AND LOAD-BEARING. `StyleAccrualPolicy.status` takes the row's
    /// PREVIOUS status and re-verifies anything already verified whose
    /// agreement is still above `demotionAgreement` — the hysteresis that stops
    /// a tenet oscillating across the promotion line on single observations.
    /// `row.status` is only ever written here and in `restore`, so dropping
    /// this would leave `previous` permanently `.candidate`, make
    /// `demotionAgreement` dead code, and demote verified tenets the moment
    /// agreement dipped. It used to also report drift; that went with the
    /// checksum machinery, and this is the half that was doing real work.
    public func publish(at now: Date = Date()) {
        let current = observedTenets(at: now)
        box.withLock { rows in
            for tenet in current {
                let key = Key(
                    scopeKind: tenet.scope.kind,
                    identity: tenet.scope.identity,
                    dimension: tenet.dimension)
                guard var row = rows[key] else { continue }
                row.status = tenet.status
                rows[key] = row
            }
        }
    }

    /// Drop evidence that has gone quiet, and any row left empty by it.
    ///
    /// Only observed contributions are swept — assertions, vetoes and imports
    /// are STATEMENTS, not observations, and have no freshness to lose. That
    /// asymmetry is the point: what you said stays said however long it has
    /// been since you said it.
    ///
    /// Returns the tenet keys that went away, so the caller can say so.
    @discardableResult
    public func evictDecayed(at now: Date = Date()) -> [String] {
        var removed: [String] = []
        box.withLock { rows in
            for (key, var row) in rows {
                let before = row.contributions.count
                row.contributions = row.contributions.filter { _, contribution in
                    StyleRecency.weight(at: contribution.at, now: now)
                        >= StyleRecency.decayFloor
                }
                guard row.contributions.count != before else { continue }
                if row.isEmpty {
                    // Readable, because these land verbatim in the Corpus
                    // activity ledger — a tenetKey is a hash and reads as
                    // noise in the pane.
                    let scope = StyleScope(kind: key.scopeKind, identity: key.identity)
                    removed.append("\(scope.displayName) · \(key.dimension.rawValue)")
                    rows[key] = nil
                } else {
                    rows[key] = row
                }
            }
        }
        return removed
    }

    /// Only what may speak, most-confident first.
    public func renderable(at now: Date = Date()) -> [StyleTenet] {
        tenets(at: now).filter(\.isRenderable).sorted {
            $0.confidence == $1.confidence
                ? $0.tenetKey < $1.tenetKey
                : $0.confidence > $1.confidence
        }
    }

    /// What may speak for ONE Ability — the block that goes into that
    /// Ability's dispatch.
    ///
    /// This is the chain: `.ability("design")` tenets plus the tenets of every
    /// application and language realizing design. It is why the schema attaches
    /// to the Ability rather than to the tool — a design tenet steers Sketch,
    /// and would steer Figma too, while a Sketch tenet stays with Sketch.
    public func renderable(
        forAbility ability: AbilityID,
        applications: [String],
        languages: [String] = [],
        projectRoot: String? = nil,
        at now: Date = Date()
    ) -> [StyleTenet] {
        renderable(at: now).filter { tenet in
            switch tenet.scope.kind {
            case .ability: return tenet.scope.identity == ability.rawValue
            case .application: return applications.contains(tenet.scope.identity ?? "")
            case .language: return languages.contains(tenet.scope.identity ?? "")
            // A project tenet reaches whatever is working inside that
            // repository — one pass here, rather than a second full
            // `renderable` sweep at the call site, which was the exact
            // duplicate-pass pattern `tenets(observed:)` was built to end.
            case .project: return projectRoot != nil && tenet.scope.identity == projectRoot
            case .unknown: return false
            }
        }
    }

    /// Every distinct subject the corpus currently has evidence for — one per
    /// ABILITY.
    ///
    /// This read the `.application` rung until the ladder was corrected, which
    /// is why it could report nothing at all: only two of ten dimensions ever
    /// reached `.application`, so a corpus of craft and notation habits had no
    /// subject and its profile was never written. Persistence now iterates the
    /// producer registry rather than inferring subjects from evidence, and this
    /// answers the inspector's "what does the corpus actually hold".
    public func subjects(at now: Date = Date()) -> [String] {
        var seen = Set<String>()
        for tenet in tenets(at: now)
        where tenet.scope.kind == .ability {
            if let identity = tenet.scope.identity { seen.insert(identity) }
        }
        return seen.sorted()
    }

    /// The tenets belonging in one subject's profile.
    ///
    /// THE SUBJECT IS AN ABILITY. Its own rung, the notations it reads, the
    /// applications it is observed through, and every project it has worked in
    /// — one document describing a kind of work, rather than one describing an
    /// editor.
    public func tenets(
        forSubject subject: String,
        applications: [String],
        languages: [String],
        at now: Date = Date()
    ) -> [StyleTenet] {
        tenets(at: now).filter { tenet in
            switch tenet.scope.kind {
            case .ability: return tenet.scope.identity == subject
            case .application: return applications.contains(tenet.scope.identity ?? "")
            case .language: return languages.contains(tenet.scope.identity ?? "")
            case .project, .unknown: return true
            }
        }
    }

    /// Restore observed tenets from the durable profile after a relaunch.
    /// Counts are rehydrated so evidence continues rather than restarting —
    /// the one thing the observation-fact design got right and worth keeping.
    public func restore(_ tenets: [StyleTenet]) {
        // Assertions restore as assertions — rehydrating one into the tallies
        // would turn a statement of intent into ten votes of evidence and let
        // the corpus outvote it, which is exactly the authority it was given
        // to avoid.
        assertedBox.withLock { store in
            for tenet in tenets where tenet.provenance.isAsserted && tenet.isMeaningful {
                store[tenet.tenetKey] = tenet
            }
        }
        // A RESTORED TENET IS ONE SYNTHETIC CONTRIBUTION, not a rebuilt set.
        // The portable format carries a rounded summary, never the per-source
        // opinions behind it, so this is the honest reconstruction: one
        // opinion, dated when the summary was, decaying like any other — AS A
        // UNIT, because a summary has one date. What keeps that honest is
        // displacement in `record`: each file that re-observes the dimension
        // takes its share back out of the blob, so the live corpus replaces
        // the snapshot instead of stacking on top of it, and support cannot
        // ratchet across save/restore/edit cycles.
        box.withLock { rows in
            for tenet in tenets where tenet.provenance.isObserved && tenet.isMeaningful {
                let key = Key(
                    scopeKind: tenet.scope.kind,
                    identity: tenet.scope.identity,
                    dimension: tenet.dimension)
                var row = rows[key] ?? StyleEvidenceRow()
                row.contributions[Self.restoredSource] = StyleContribution(
                    value: tenet.value,
                    weight: max(1, tenet.support),
                    vocabulary: tenet.vocabulary,
                    sourceHash: "",
                    at: tenet.lastObservedAt)
                // Restored one weight SHORT of a tie: both blobs share one
                // date, so equal weights restore as an exact tie forever,
                // `leader()` refuses to pick, and a persisted `support ==
                // counter` tenet silently vanishes. The persisted leader
                // stays the leader.
                let counterWeight = min(tenet.counter, max(1, tenet.support) - 1)
                if counterWeight > 0,
                   let other = tenet.dimension.values.first(where: { $0 != tenet.value }) {
                    row.contributions[Self.restoredCounterSource] = StyleContribution(
                        value: other, weight: counterWeight, vocabulary: [],
                        sourceHash: "", at: tenet.lastObservedAt)
                }
                row.status = tenet.status
                rows[key] = row
            }
        }
    }

    /// Reserved source keys for the restored snapshot — real units can never
    /// collide with them (`record` requires a non-reserved source to displace
    /// them, and the crawl's keys never start with the separator).
    static let restoredSource = "\u{1F}restored"
    static let restoredCounterSource = "\u{1F}restored-counter"

    /// Re-install vetoes from the durable profile. Additive, like `restore` —
    /// a veto said in a previous session stays said.
    public func restoreVetoes(_ keys: [String]) {
        vetoedBox.withLock { $0.formUnion(keys) }
    }

    /// The tenets to WRITE into one subject's durable document.
    ///
    /// Differs from `tenets(forSubject:)` in exactly two ways, both of which
    /// exist because persistence is not rendering:
    ///   · vetoed tenets ARE included — the veto travels separately
    ///     (`StyleProfile.vetoedTenetKeys`), so lifting it after a relaunch
    ///     still has evidence to reveal. Filtering here made a veto a
    ///     permanent deletion the moment the app quit.
    ///   · imports are NOT included — an imported tenet is a hypothesis, and
    ///     `restore` never rehydrates them, so persisting them wrote bytes
    ///     that silently evaporated on every launch.
    public func persistableTenets(
        forSubject subject: String,
        applications: [String],
        languages: [String],
        at now: Date = Date()
    ) -> [StyleTenet] {
        let asserted = assertedBox.withLock { $0 }
        var byKey: [String: StyleTenet] = [:]
        for tenet in observedTenets(at: now) { byKey[tenet.tenetKey] = tenet }
        for (key, tenet) in asserted { byKey[key] = tenet }
        return byKey.values
            .filter { tenet in
                switch tenet.scope.kind {
                case .ability: return tenet.scope.identity == subject
                case .application: return applications.contains(tenet.scope.identity ?? "")
                case .language: return languages.contains(tenet.scope.identity ?? "")
                case .project, .unknown: return true
                }
            }
            .sorted { $0.tenetKey < $1.tenetKey }
    }

    public func reset() {
        box.withLock { $0 = [:] }
        importedBox.withLock { $0 = [:] }
        assertedBox.withLock { $0 = [:] }
        vetoedBox.withLock { $0 = [] }
    }

    /// Clear the corpus tallies but KEEP what was said by hand. Re-indexing a
    /// project should not silently discard the user's own statements along
    /// with the inferences drawn from their code.
    public func resetObservations() {
        box.withLock { $0 = [:] }
    }

}
