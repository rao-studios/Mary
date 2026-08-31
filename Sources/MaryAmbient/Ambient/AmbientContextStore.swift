//
//  AmbientContextStore.swift
//  MaryAmbient
//
//  WHAT: Short-term in-memory awareness for this machine and conversation.
//  IN:   AX / observers / Skills
//  OUT:  prompt assembly (tiers in order). Durable retrieval → Totem.
//  PIN:  Surface expires by drop, never degrade. Facts degrade with age.
//
//  Tiers:
//    0 SURFACE   AmbientSurface / noteSurface → AmbientContextStore+Surface
//    1 FACTS     register / replacePerceived
//    2 SELECTION recordSelection / noteWorld (source-owned, never inferred)
//

import CryptoKit
import MaryFoundation
import Foundation
import os

/// Mutable-once route holder after classifiers run inside a frozen turn.
/// PIN: TaskLocal cannot be reassigned; this box can. Caller: runTurnBody.
public final class AmbientRouteTurnState: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock<AmbientRoute?>(initialState: nil)

    public init() {}

    public func note(_ route: AmbientRoute) { box.withLock { $0 = route } }
    public func current() -> AmbientRoute? { box.withLock { $0 } }
}

/// Per-request route holder. Nil = this turn has not routed yet.
/// PIN: never fall back to another turn's process-global snapshot.
public enum AmbientRouteTurnContext {
    @TaskLocal public static var state: AmbientRouteTurnState?
}

/// A normalized form of awareness a support plugin can provide.
public enum AmbientSense: String, CaseIterable, Hashable, Sendable, Codable {
    case workspace
    case selection
    case hover
}

public enum AmbientWorldTier: Int, Sendable, Equatable, CaseIterable, Codable {
    case hover = 1
    case activation = 2
    case selection = 3

    public var displayName: String {
        switch self {
        case .hover: return "hover"
        case .activation: return "active application"
        case .selection: return "selection"
        }
    }

    public var freshFor: TimeInterval {
        switch self {
        case .hover: return 3
        case .activation: return 15
        case .selection: return AmbientSamplingCadence.activeInterval * 2
        }
    }
}

/// Process-wide, lock-protected short-term awareness.
public final class AmbientContextStore: @unchecked Sendable {

    public static let shared = AmbientContextStore()

    /// Cap on named reads per lane. Oldest first.
    /// PIN: `(world, namedRead(phrase))` is the only unbounded key half.
    public static let namedReadCap = 4

    private let box = OSAllocatedUnfairLock<[AmbientKey: AmbientFact]>(initialState: [:])
    /// TIER 0 — one surface per family lane. Access: AmbientContextStore+Surface.
    /// `internal` so the extension and `@testable` reach it.
    let surfaceBox =
        OSAllocatedUnfairLock<[AmbientPlace: AmbientSurface]>(initialState: [:])
    /// Focus-arbiter lead as a place (a world cannot name which app on `.applications`).
    /// World callers read `place.attention`.
    private let leadBox =
        OSAllocatedUnfairLock<(place: AmbientPlace, at: Date)?>(initialState: nil)
    private let utteranceBox = OSAllocatedUnfairLock<String>(initialState: "")
    /// Embedding search string this turn (utterance + world + history).
    private let routingQueryBox = OSAllocatedUnfairLock<String>(initialState: "")
    /// Turn container. OUT: ReferenceDecision.
    private let referenceBox = OSAllocatedUnfairLock<ReferenceDecision>(initialState: .none)
    /// Route for retrieval and prompt assembly.
    private let routeBox = OSAllocatedUnfairLock<AmbientRoute?>(initialState: nil)
    private let worldBox = OSAllocatedUnfairLock<AmbientWorld.Snapshot?>(initialState: nil)
    /// Canonical source-owned highlight. Fact/attention project at read time.
    /// PIN: watermarks outlive a clear so a delayed AX read cannot resurrect.
    private struct SelectionState {
        var handoff: AmbientSelectionHandoff?
        /// Last selection handed to a turn. Freshness window only; not standing state.
        /// PIN: ordinary turns cannot see it; new packet or lifecycle clears it.
        var recentClaimedHandoff: AmbientSelectionHandoff?
        var sourceMutationAt: [SelectionSource: Date] = [:]
        /// Semantic tombstones after a turn claims a packet. Process-session, not per AX object.
        /// PIN: exact-source caret opens a one-selection rearm fence; h2 must not forget h1.
        var deliveredSelections: [SelectionProcess: [DeliveredSelection]] = [:]
        /// Process-wide ordering watermark. Title caret must not clear a body highlight;
        /// a late read from that other surface must not revive after accept/clear/claim.
        var processMutationAt: [SelectionProcess: Date] = [:]
    }
    private let selectionStateBox = OSAllocatedUnfairLock<SelectionState>(
        initialState: .init())
    private static let selectionMutationRetention: TimeInterval = 60
    private let observerBox =
        OSAllocatedUnfairLock<(any AmbientObserving)?>(initialState: nil)

    // No durable-learning sinks yet. Seam: AmbientObserving (one protocol).
    // OUT: Totem when that lane attaches.

    /// Held facts as embeddable records for ranking. Facts are evidence, never mutation targets.
    /// OUT: AmbientElementIndexStore
    private let elementIndexStore: AmbientElementIndexStore

    public init(elementIndexStore: AmbientElementIndexStore? = nil) {
        self.elementIndexStore = elementIndexStore ?? AmbientElementIndexStore()
    }

    /// The gate's partition for one world's facts.
    public static func scope(attention: AmbientAttention) -> AmbientElementScope {
        AmbientElementScope(place: .lane(attention), key: attention.rawValue)
    }

    /// Republish one world's facts. Outside the fact lock; the store vectorizes.
    private func publishElements(attentions: Set<AmbientAttention>, at now: Date) {
        for attention in attentions {
            elementIndexStore.noteElements(
                AmbientFactRule.records(
                    for: facts(attention: attention, at: now),
                    scope: Self.scope(attention: attention)),
                scope: Self.scope(attention: attention))
        }
    }

    /// Held facts ranked to a spoken phrase. OUT: AmbientReferenceGate.
    public func rankedFacts(
        matching phrase: String, attention: AmbientAttention
    ) -> [RankedAmbientElement] {
        AmbientReferenceGate.rank(
            phrase: phrase,
            scope: Self.scope(attention: attention),
            store: elementIndexStore)
    }

    // MARK: - Writers

    /// Register a fact. Superseding write replaces the slot; prune on the way through.
    /// PIN: selections go through `recordSelection` — a fact lacks source/capture ordering.
    public func register(_ fact: AmbientFact, at now: Date = Date()) {
        guard fact.slot != .selection else { return }
        box.withLock { facts in
            Self.prune(&facts, at: now)
            facts[fact.key] = fact
            Self.capNamedReads(&facts, attention: fact.attention, application: fact.application)
        }
        publishElements(attentions: [fact.attention], at: now)
    }

    public func register(_ facts: [AmbientFact], at now: Date = Date()) {
        let nonSelectionFacts = facts.filter { $0.slot != .selection }
        guard !nonSelectionFacts.isEmpty else { return }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            for fact in nonSelectionFacts { stored[fact.key] = fact }
            // One pass per lane. Apps sharing `.applications` each own a read budget.
            // OUT: capNamedReads
            var lanes: Set<AmbientPlace> = []
            for fact in nonSelectionFacts { lanes.insert(fact.place) }
            for lane in lanes {
                Self.capNamedReads(&stored, attention: lane.attention, application: lane.application)
            }
        }
        publishElements(attentions: Set(nonSelectionFacts.map(\.attention)), at: now)
    }

    /// Replace document/perception slots for one poll. Named reads untouched.
    /// PIN: `application` scopes the wipe to one lane; nil = the world's own lane.
    /// Selections do not travel here — source-owned packet, not inferred evidence.
    public func replacePerceived(
        attention: AmbientAttention,
        application: String? = nil,
        with facts: [AmbientFact],
        at now: Date = Date()
    ) {
        // Polls cannot reconstruct an interaction; drop selection facts.
        let nonSelectionFacts = facts.filter { $0.slot != .selection }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            // Snapshot keys before mutate; live `keys` view aliases.
            for key in Array(stored.keys) where key.attention == attention
                && key.application == application
                && key.slot.isPerceived {
                stored[key] = nil
            }
            for fact in nonSelectionFacts where fact.slot.isPerceived {
                stored[fact.key] = fact
            }
        }
        emit(nonSelectionFacts)
        publishElements(attentions: [attention], at: now)
    }

    /// Representation went dark. Perceived facts go; a read survives.
    /// PIN: selection is not this teardown (source-app input). Lane-scoped: place is the lane.
    /// OUT: forget(attention:) / explicit deselection / expiry for selection.
    public func forgetPerceived(place: AmbientPlace) {
        box.withLock { stored in
            for key in Array(stored.keys)
            where key.place == place && key.slot.isPerceived {
                stored[key] = nil
            }
        }
        worldBox.withLock { snapshot in
            guard snapshot?.attention == place.attention,
                  snapshot?.tier != .selection
            else { return }
            snapshot = nil
        }
    }

    /// World-wide teardown — every lane, including every app riding the world.
    /// PIN: world-typed on purpose; a place names one lane. Callers: disable/quit, tests.
    public func forget(attention: AmbientAttention) {
        box.withLock { stored in
            for key in Array(stored.keys) where key.attention == attention { stored[key] = nil }
        }
        worldBox.withLock { snapshot in
            guard snapshot?.attention == attention else { return }
            snapshot = nil
        }
        discardSelection(attention: attention)
    }

    public func forget(key: AmbientKey) {
        box.withLock { $0[key] = nil }
        worldBox.withLock { snapshot in
            guard snapshot?.key == key else { return }
            snapshot = nil
        }
    }

    /// Turn-loop write-back: spoken note on a fact. Match by content containment.
    /// PIN: voice passages are the fact's rendered text; brain never learns store keys.
    @discardableResult
    public func noteSpoken(
        contentsIn passages: [String], note: String, at now: Date = Date()
    ) -> [AmbientKey] {
        let trimmed = passages.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [] }
        let clipped = String(note.prefix(160))
        return box.withLock { stored -> [AmbientKey] in
            var touched: [AmbientKey] = []
            for (key, fact) in Array(stored) where !fact.content.isEmpty {
                guard trimmed.contains(where: { $0.contains(fact.content) }) else { continue }
                var updated = fact
                updated.spokenAt = now
                updated.spokenNote = clipped.isEmpty ? nil : clipped
                stored[key] = updated
                touched.append(key)
            }
            return touched
        }
    }

    /// Lead copy of tracker-derived focus. Must not outlive its source.
    /// PIN: lead horizon ≠ signal horizon; aligned to FocusSignal.coActiveHorizon.
    public static let leadHorizon: TimeInterval = FocusSignal.coActiveHorizon

    /// Place the focus arbiter gave the lead this turn. Canonical writer.
    public func noteLead(place: AmbientPlace?) {
        leadBox.withLock { $0 = place.map { ($0, Date()) } }
    }

    /// Lead as a place, decayed at `leadHorizon`.
    public func leadPlace(at now: Date = Date()) -> AmbientPlace? {
        leadBox.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.leadHorizon
            else { return nil }
            return held.place
        }
    }

    /// Utterance this turn is answering. Budget policy ranks against it.
    public func noteUtterance(_ text: String) {
        utteranceBox.withLock { $0 = text }
    }

    public func utterance() -> String {
        utteranceBox.withLock { $0 }
    }

    /// The embedding query. Falls back to the raw utterance when unset.
    public func noteRoutingQuery(_ text: String) {
        routingQueryBox.withLock { $0 = text }
    }

    public func routingQuery() -> String {
        let query = routingQueryBox.withLock { $0 }
        return query.isEmpty ? utterance() : query
    }

    /// Container this turn means. Written once by the turn loop; read everywhere.
    /// PIN: nil = nobody named a container; readers keep prior fallbacks.
    public func noteReference(_ decision: ReferenceDecision) {
        referenceBox.withLock { $0 = decision }
    }

    /// The whole decision, including a refusal.
    public func reference() -> ReferenceDecision {
        referenceBox.withLock { $0 }
    }

    /// Container only. A refusal reads as nil so nothing proceeds on one.
    public func referent() -> ResolvedReferent? {
        reference().referent
    }

    /// Publish the turn's capability and memory decision before prompt assembly.
    public func noteRoute(_ route: AmbientRoute) {
        AmbientRouteTurnContext.state?.note(route)
        routeBox.withLock { $0 = route }
    }

    public func route() -> AmbientRoute? {
        if let state = AmbientRouteTurnContext.state {
            return state.current()
        }
        return routeBox.withLock { $0 }
    }

    /// Perception publishes onward when something is listening. Structure only.
    /// PIN: never document text, titles, selections, or working contents.
    /// OUT: Totem (behavioral-corpus lane); nothing implements this yet.
    public protocol AmbientObserving: Sendable {
        func observed(_ fact: AmbientFact) async
    }

    public func setObserver(_ observer: (any AmbientObserving)?) {
        observerBox.withLock { $0 = observer }
    }

    // MARK: - Direct selection handoff

    /// Canonical selection for this interaction. Raw handoff is the only stored form.
    /// PIN: `at` is receipt; ordering uses packet `capturedAt`. Fact/attention are projections.
    @discardableResult
    public func recordSelection(
        _ handoff: AmbientSelectionHandoff,
        at now: Date = Date()
    ) -> Bool {
        guard !handoff.text.isEmpty, handoff.isFresh(at: now) else { return false }
        let accepted = selectionStateBox.withLock { state -> Bool in
            Self.pruneSelectionMutations(&state, at: now)
            let source = SelectionSource(handoff)
            let process = SelectionProcess(handoff)
            if let mutation = state.processMutationAt[process], mutation > handoff.capturedAt {
                return false
            }
            if let mutation = state.sourceMutationAt[source], mutation > handoff.capturedAt {
                return false
            }
            if let current = state.handoff {
                if current.capturedAt > handoff.capturedAt { return false }
                // Generic AX poll must not erase a richer adapter-resolved scope.
                // PIN: later receipt ≠ new interaction if the value is the same.
                if Self.isScopeDowngrade(handoff, of: current, at: now) {
                    return false
                }
                // Weaker periodic scan of another child must not replace a direct packet.
                // PIN: source-evidence ordering, not a document/title heuristic.
                if Self.isCrossSurfaceFallback(
                    handoff, weakerThan: current, at: now) {
                    return false
                }
                // Same interaction does not renew the lease. Duplicate events are idempotent.
                if current.attention == handoff.attention,
                   current.applicationID == handoff.applicationID,
                   current.processID == handoff.processID,
                   current.sourceSurfaceID == handoff.sourceSurfaceID,
                   current.text == handoff.text,
                   current.range == handoff.range,
                   // Workspace/project/document identity is part of interaction identity.
                   // PIN: missing field stays conservative (one process, no AX surface id).
                   !ProvenSelectionScope(current.scope)
                    .isDistinct(from: handoff.scope),
                   // Exact observer may upgrade identical generic provenance; reverse is a duplicate.
                   !(handoff.sourceEvidence.rank > current.sourceEvidence.rank),
                   current.isFresh(at: now) {
                    return false
                }
            }
            // Physical highlight can outlive Mary's use (canvas descendants, queued AX).
            // PIN: exact-source clear or a distinct selection is the rearm boundary.
            if var delivered = state.deliveredSelections[process] {
                let matchingIndices = delivered.indices.filter {
                    delivered[$0].matches(handoff)
                }
                if !matchingIndices.isEmpty {
                    // Same-range h1 vs queued AX: only exact-source caret opens a rearm fence.
                    // PIN: sibling/process-sharing surface stays tombstoned after that clear.
                    let canRearm = matchingIndices.allSatisfy { index in
                        let deliveredSelection = delivered[index]
                        guard deliveredSelection.source == source,
                              handoff.sourceEvidence.isExact,
                              let clearedAt = deliveredSelection.clearedAt
                        else { return false }
                        return clearedAt > deliveredSelection.claimedAt
                            && handoff.capturedAt > clearedAt
                    }
                    guard canRearm else { return false }
                    delivered.removeAll { $0.matches(handoff) }
                    state.deliveredSelections[process] = delivered.isEmpty ? nil : delivered
                }
            }
            state.handoff = handoff
            state.recentClaimedHandoff = nil
            state.sourceMutationAt[source] = max(
                state.sourceMutationAt[source] ?? .distantPast, handoff.capturedAt)
            // Title caret must not clear a body highlight; ordering is still process-wide.
            state.processMutationAt[process] = max(
                state.processMutationAt[process] ?? .distantPast, handoff.capturedAt)
            return true
        }
        guard accepted else { return false }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            // Drop leftover selection facts; the packet is the only participant.
            for key in Array(stored.keys) where key.slot == .selection {
                stored[key] = nil
            }
        }
        worldBox.withLock { snapshot in
            guard snapshot?.tier == .selection else { return }
            snapshot = nil
        }
        emit([Self.selectionFact(from: handoff)])
        return true
    }

    /// Empty-selection event clears only the source that set the handoff.
    /// PIN: focus change / other-app poll / unparseable range is not deselection.
    public func clearSelection(
        applicationID: String,
        processID: Int32? = nil,
        sourceSurfaceID: UInt? = nil,
        /// Process teardown may clear every AX surface under that PID.
        /// PIN: observer/poll caret leaves this false (fail closed).
        allSurfaces: Bool = false,
        at capturedAt: Date = Date(),
        receivedAt now: Date = Date()
    ) {
        let result = selectionStateBox.withLock { state -> (removed: AmbientSelectionHandoff?, invalidated: Bool) in
            Self.pruneSelectionMutations(&state, at: now)
            let source = processID.map {
                SelectionSource(
                    applicationID: applicationID, processID: $0,
                    sourceSurfaceID: sourceSurfaceID)
            }
            let process = processID.map {
                SelectionProcess(applicationID: applicationID, processID: $0)
            }
            if let recent = state.recentClaimedHandoff,
               recent.applicationID == applicationID,
               processID == nil || recent.processID == processID,
               allSurfaces || recent.sourceSurfaceID == sourceSurfaceID,
               recent.capturedAt <= capturedAt {
                state.recentClaimedHandoff = nil
            }
            // Clear is a source mutation even if it cannot remove the packet.
            // PIN: advance process watermark so a pre-event AX read cannot revive.
            if let process {
                state.processMutationAt[process] = max(
                    state.processMutationAt[process] ?? .distantPast, capturedAt)
            }
            // Keep source-local watermark even if another app owns the global handoff.
            if let source, let mutation = state.sourceMutationAt[source], mutation > capturedAt {
                return (nil, false)
            }
            if let source {
                state.sourceMutationAt[source] = max(
                    state.sourceMutationAt[source] ?? .distantPast, capturedAt)
            }
            if allSurfaces, let process {
                state.deliveredSelections[process] = nil
            } else if let process,
                      let source,
                      state.deliveredSelections[process] != nil {
                // Caret opens a rearm fence for the exact AX surface only.
                // PIN: sibling can retain old h1; only later exact capture from this source consumes it.
                var delivered = state.deliveredSelections[process] ?? []
                for index in delivered.indices {
                    guard delivered[index].source == source,
                          delivered[index].claimedAt <= capturedAt
                    else { continue }
                    delivered[index].clearedAt = max(
                        delivered[index].clearedAt ?? .distantPast,
                        capturedAt)
                }
                state.deliveredSelections[process] = delivered
            }
            guard let current = state.handoff else {
                return (nil, processID != nil)
            }
            guard current.applicationID == applicationID,
                  processID == nil || current.processID == processID,
                  allSurfaces || current.sourceSurfaceID == sourceSurfaceID,
                  current.capturedAt <= capturedAt
            else { return (nil, false) }
            let currentSource = SelectionSource(current)
            state.sourceMutationAt[currentSource] = max(
                state.sourceMutationAt[currentSource] ?? .distantPast, capturedAt)
            state.handoff = nil
            return (current, true)
        }
        guard result.invalidated else { return }
        guard result.removed != nil else { return }
        worldBox.withLock { snapshot in
            guard snapshot?.applicationID == applicationID,
                  snapshot?.tier == .selection
            else { return }
            snapshot = nil
        }
    }

    /// Revoke unclaimed selection when a different external app activates.
    /// PIN: missing app/pid is conservative. Caller: non-Mary activations only.
    @discardableResult
    public func revokeUnclaimedSelectionForExternalActivation(
        applicationID: String?,
        processID: Int32?,
        at now: Date = Date()
    ) -> Bool {
        let removed = selectionStateBox.withLock { state -> AmbientSelectionHandoff? in
            Self.pruneSelectionMutations(&state, at: now)
            if let recent = state.recentClaimedHandoff {
                let activationIsRecentSource = applicationID.map {
                    $0 == recent.applicationID
                } == true && processID.map {
                    $0 == recent.processID
                } == true
                if !activationIsRecentSource {
                    state.recentClaimedHandoff = nil
                }
            }
            guard let current = state.handoff else { return nil }
            let activationIsSameSource = applicationID.map {
                $0 == current.applicationID
            } == true && processID.map {
                $0 == current.processID
            } == true
            guard !activationIsSameSource
            else { return nil }
            let source = SelectionSource(current)
            let process = SelectionProcess(current)
            state.sourceMutationAt[source] = max(
                state.sourceMutationAt[source] ?? .distantPast, now)
            state.processMutationAt[process] = max(
                state.processMutationAt[process] ?? .distantPast, now)
            state.handoff = nil
            return current
        }
        guard let removed else { return false }
        worldBox.withLock { snapshot in
            guard snapshot?.tier == .selection,
                  snapshot?.applicationID == removed.applicationID
            else { return }
            snapshot = nil
        }
        return true
    }

    /// Raw handoff, exact and never prompt-clipped. Plugin enrich only when source matches.
    public func selectionHandoff(
        attention: AmbientAttention? = nil,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        if let snapshot = AmbientSelectionTurnContext.snapshot {
            guard let handoff = snapshot.handoff,
                  attention == nil || handoff.attention == attention
            else { return nil }
            return handoff
        }
        return currentSelectionHandoff(attention: attention, at: now)
    }

    /// Selection prompt/execution may consume. Applies the immutable route first.
    /// PIN: raw handoff can remain for diagnostics even if the request named a conflicting app.
    public func routedSelectionHandoff(
        attention: AmbientAttention? = nil,
        requiringWritingTarget: Bool = false,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        guard let route = route(),
              !requiringWritingTarget || route.writingTarget == .selection,
              let handoff = selectionHandoff(attention: attention, at: now),
              route.admitsSelectionHandoff(handoff)
        else { return nil }
        return handoff
    }

    /// Latest unclaimed process-wide packet; ignores turn-local snapshot.
    /// PIN: claimed packets stay unavailable so a slow poll cannot republish.
    public func liveSelectionHandoff(
        attention: AmbientAttention? = nil,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        currentSelectionHandoff(attention: attention, at: now)
    }

    private func currentSelectionHandoff(
        attention: AmbientAttention? = nil,
        application: String? = nil,
        at now: Date
    ) -> AmbientSelectionHandoff? {
        selectionStateBox.withLock { state in
            Self.pruneSelectionMutations(&state, at: now)
            guard let handoff = state.handoff, handoff.isFresh(at: now) else {
                state.handoff = nil
                return nil
            }
            guard attention == nil || handoff.attention == attention else { return nil }
            // Lane asked for is a lane required. Nil = the world's own, not any.
            guard application == nil || handoff.application == application else { return nil }
            return handoff
        }
    }

    /// Claim the selection for one turn. After this, only the task-local caller sees it.
    /// PIN: no global release. Time alone must not re-arm; source clear + exact capture can.
    public func snapshotSelectionForTurn(
        allowingRecentClaimed: Bool = false,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        selectionStateBox.withLock { state in
            Self.pruneSelectionMutations(&state, at: now)
            guard let handoff = state.handoff, handoff.isFresh(at: now) else {
                state.handoff = nil
                guard allowingRecentClaimed,
                      let recent = state.recentClaimedHandoff,
                      recent.isFresh(at: now)
                else { return nil }
                return recent
            }
            let source = SelectionSource(handoff)
            let process = SelectionProcess(handoff)
            var delivered = state.deliveredSelections[process] ?? []
            // Replace only the equivalent tombstone; do not grow the ledger.
            delivered.removeAll { $0.matches(handoff) }
            delivered.append(DeliveredSelection(
                handoff, source: source, claimedAt: now))
            state.deliveredSelections[process] = delivered
            // Delayed pre-turn AX must not republish; captures begun after remain eligible.
            state.sourceMutationAt[source] = max(
                state.sourceMutationAt[source] ?? .distantPast, now)
            state.processMutationAt[process] = max(
                state.processMutationAt[process] ?? .distantPast, now)
            state.recentClaimedHandoff = handoff
            state.handoff = nil
            return handoff
        }
    }

    /// CAS: enrich only if this is still the exact capture the plugin inspected.
    /// PIN: a slow body read must not pair with a newer selection.
    @discardableResult
    public func enrichSelection(
        id: UUID,
        with enrichment: AmbientSelectionEnrichment,
        at now: Date = Date()
    ) -> Bool {
        let enriched = selectionStateBox.withLock { state -> AmbientSelectionHandoff? in
            Self.pruneSelectionMutations(&state, at: now)
            guard var current = state.handoff,
                  current.id == id,
                  current.isFresh(at: now)
            else { return nil }
            if let scope = enrichment.scope {
                guard let merged = Self.merging(scope, into: current.scope) else {
                    return nil
                }
                current.scope = merged
            }
            if let subject = enrichment.subject { current.subject = subject }
            if let surrounding = enrichment.surroundingText {
                current.surroundingText = surrounding
            }
            if let bounds = enrichment.documentBounds {
                current.documentBounds = bounds
            }
            if let total = enrichment.documentTotal { current.documentTotal = total }
            if let typed = enrichment.documentTypedRange {
                current.documentTypedRange = typed
            }
            state.handoff = current
            return current
        }
        guard let enriched else { return false }
        emit([Self.selectionFact(from: enriched)])
        return true
    }

    public func noteWorld(_ incoming: AmbientWorld.Snapshot, at now: Date = Date()) {
        // Selection attention is `recordSelection` only; reject standalone here.
        guard incoming.tier != .selection else { return }
        guard incoming.isFresh(at: now) else { return }
        worldBox.withLock { current in
            guard let existing = current, existing.isFresh(at: now) else {
                current = incoming
                return
            }
            if incoming.tier.rawValue >= existing.tier.rawValue {
                current = incoming
            }
        }
        emit(facts(attention: incoming.attention, at: now))
    }

    public func world(at now: Date = Date()) -> AmbientWorld.Snapshot? {
        if let snapshot = AmbientSelectionTurnContext.snapshot {
            // Task-local freezes selection only. Hover/activation still apply.
            if let handoff = snapshot.handoff {
                return Self.selectionWorld(from: handoff)
            }
        } else if let handoff = currentSelectionHandoff(at: now) {
            return Self.selectionWorld(from: handoff)
        }
        return worldBox.withLock { value -> AmbientWorld.Snapshot? in
            guard let value, value.isFresh(at: now) else {
                value = nil
                return nil
            }
            return value
        }
    }

    // MARK: - Readers

    /// Live facts, ordered (place, slot, key). Prompt and pane must agree.
    public func facts(at now: Date = Date()) -> [AmbientFact] {
        var live = box.withLock { stored -> [AmbientFact] in
            Self.prune(&stored, at: now)
            return Array(stored.values)
        }
        // Selection projects from the source packet. Turn-local: no live leak.
        if let snapshot = AmbientSelectionTurnContext.snapshot {
            live.removeAll { $0.slot == .selection }
            if let handoff = snapshot.handoff {
                live.append(Self.selectionFact(from: handoff))
            }
        } else if let handoff = currentSelectionHandoff(at: now) {
            live.removeAll { $0.slot == .selection }
            live.append(Self.selectionFact(from: handoff))
        }
        return live.sorted(by: Self.ordered)
    }

    /// Every lane in a world (`.applications` = every registered app).
    /// PIN: not `facts(place: .lane(attention))` — that is the world's own lane only.
    public func facts(attention: AmbientAttention, at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { $0.attention == attention }
    }

    /// One lane's facts. `facts(attention:)` is the roster (every app on `.applications`).
    public func facts(place: AmbientPlace, at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { $0.place == place }
    }

    /// One slot. `application` narrows to one lane; nil = the world's own lane.
    public func fact(
        attention: AmbientAttention,
        application: String? = nil,
        slot: AmbientSlot,
        at now: Date = Date()
    ) -> AmbientFact? {
        if slot == .selection {
            if let snapshot = AmbientSelectionTurnContext.snapshot {
                guard let handoff = snapshot.handoff,
                      handoff.attention == attention,
                      handoff.application == application
                else { return nil }
                return Self.selectionFact(from: handoff)
            }
            if let handoff = currentSelectionHandoff(
                attention: attention, application: application, at: now) {
                return Self.selectionFact(from: handoff)
            }
            return nil
        }
        return box.withLock { stored -> AmbientFact? in
            let fact = stored[AmbientKey(attention: attention, application: application, slot: slot)]
            guard let fact, !fact.isExpired(at: now) else { return nil }
            return fact
        }
    }

    /// Held reads only (pane `read:` rows). Standing digests are not reads.
    public func reads(at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter(\.slot.isRead)
    }

    /// Facts with no live window: held reads plus eyeless-source digests.
    /// PIN: pane joins cards per watched world; this query is the debugger hatch.
    public func unwindowed(at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { !$0.slot.isPerceived }
    }

    /// Reads registered at or after `date`. Turn loop: landed vs discarded.
    /// OUT: ReadRoute.registered / .discarded
    public func reads(since date: Date, at now: Date = Date()) -> [AmbientFact] {
        reads(at: now).filter { $0.capturedAt >= date }
    }

    /// Test isolation. Process-wide box must not leak between suites.
    public func clear() {
        box.withLock { $0 = [:] }
        surfaceBox.withLock { $0 = [:] }
        leadBox.withLock { $0 = nil }
        utteranceBox.withLock { $0 = "" }
        routingQueryBox.withLock { $0 = "" }
        routeBox.withLock { $0 = nil }
        worldBox.withLock { $0 = nil }
        selectionStateBox.withLock { $0 = .init() }
        // Observer stays. Reset empties belief; it does not detach listeners.
    }

    // MARK: - Internals

    private struct SelectionSource: Hashable {
        let applicationID: String
        let processID: Int32
        let sourceSurfaceID: UInt?

        public init(
            applicationID: String,
            processID: Int32,
            sourceSurfaceID: UInt? = nil
        ) {
            self.applicationID = applicationID
            self.processID = processID
            self.sourceSurfaceID = sourceSurfaceID
        }

        public init(_ handoff: AmbientSelectionHandoff) {
            applicationID = handoff.applicationID
            processID = handoff.processID
            sourceSurfaceID = handoff.sourceSurfaceID
        }
    }

    private struct SelectionProcess: Hashable {
        let applicationID: String
        let processID: Int32

        public init(applicationID: String, processID: Int32) {
            self.applicationID = applicationID
            self.processID = processID
        }

        public init(_ handoff: AmbientSelectionHandoff) {
            self.init(applicationID: handoff.applicationID, processID: handoff.processID)
        }
    }

    /// Process-level tombstone after a turn claims a packet. No count-eviction.
    /// PIN: id/capture time absent from identity. Text is SHA-256 only; collision fails closed.
    private struct DeliveredSelection {
        let source: SelectionSource
        let attention: AmbientAttention
        let provenScope: ProvenSelectionScope
        let textIdentity: SelectionTextIdentity
        let range: Range<Int>?
        let claimedAt: Date
        /// Exact-source caret after claim. Does not remove the tombstone; opens one rearm.
        var clearedAt: Date?

        public init(
            _ handoff: AmbientSelectionHandoff,
            source: SelectionSource,
            claimedAt: Date
        ) {
            self.source = source
            attention = handoff.attention
            provenScope = ProvenSelectionScope(handoff.scope)
            textIdentity = SelectionTextIdentity(handoff.text)
            range = handoff.range
            self.claimedAt = claimedAt
        }

        func matches(_ handoff: AmbientSelectionHandoff) -> Bool {
            guard attention == handoff.attention,
                  !provenScope.isDistinct(from: handoff.scope),
                  textIdentity.matches(handoff.text)
            else { return false }
            // Ranges distinguish repeated words only on the same source surface.
            // PIN: unknown/other surface: equal words stay delivered until exact-source clear.
            guard source == SelectionSource(handoff) else { return true }
            // Missing range is not a new selection. Only two known unequal same-surface ranges distinguish.
            guard let range, let incomingRange = handoff.range else { return true }
            return range == incomingRange
        }
    }

    /// Document-bearing selection identity (workspace/project/document digests).
    /// PIN: absent field is not a different document. Process/AX surface live elsewhere.
    private struct ProvenSelectionScope {
        let workspaceID: SelectionTextIdentity?
        let projectID: SelectionTextIdentity?
        let documentID: SelectionTextIdentity?

        public init(_ scope: SourceScope) {
            workspaceID = scope.workspaceID.map(SelectionTextIdentity.init)
            projectID = scope.projectID.map(SelectionTextIdentity.init)
            documentID = scope.documentID.map(SelectionTextIdentity.init)
        }

        func isDistinct(from other: SourceScope) -> Bool {
            Self.differs(workspaceID, other.workspaceID)
                || Self.differs(projectID, other.projectID)
                || Self.differs(documentID, other.documentID)
        }

        private static func differs(
            _ lhs: SelectionTextIdentity?, _ rhs: String?
        ) -> Bool {
            guard let lhs, let rhs else { return false }
            return !lhs.matches(rhs)
        }
    }

    /// Content-free identity for a delivered handoff. Tombstones match late AX reports.
    private struct SelectionTextIdentity {
        let byteCount: Int
        public let digest: Data

        public init(_ text: String) {
            let bytes = Data(text.utf8)
            byteCount = bytes.count
            digest = Data(SHA256.hash(data: bytes))
        }

        func matches(_ text: String) -> Bool {
            let bytes = Data(text.utf8)
            return byteCount == bytes.count
                && digest == Data(SHA256.hash(data: bytes))
        }
    }

    /// Direct capture vs periodic scan of another AX surface. Both fingerprints must exist.
    /// PIN: missing identity is not proof they differ; ordinary time ordering applies.
    private static func isCrossSurfaceFallback(
        _ incoming: AmbientSelectionHandoff,
        weakerThan current: AmbientSelectionHandoff,
        at now: Date
    ) -> Bool {
        guard incoming.sourceEvidence.rank < current.sourceEvidence.rank,
              current.applicationID == incoming.applicationID,
              current.processID == incoming.processID,
              let currentSurface = current.sourceSurfaceID,
              let incomingSurface = incoming.sourceSurfaceID,
              currentSurface != incomingSurface,
              current.isFresh(at: now)
        else { return false }
        return true
    }

    /// Keep richer specialist scope when a generic provider repeats the same value.
    /// PIN: provider arbitration, never a focus or intent rule.
    private static func isScopeDowngrade(
        _ incoming: AmbientSelectionHandoff,
        of current: AmbientSelectionHandoff,
        at now: Date
    ) -> Bool {
        guard current.isFresh(at: now),
              current.applicationID == incoming.applicationID,
              current.processID == incoming.processID,
              let currentDigest = current.valueDigest,
              currentDigest == incoming.valueDigest,
              scopeRank(incoming.scope.resolution) < scopeRank(current.scope.resolution)
        else { return false }
        return true
    }

    private static func scopeRank(_ resolution: SourceResolution) -> Int {
        switch resolution {
        case .unresolved: return 0
        case .device: return 1
        case .application: return 2
        case .window: return 3
        case .workspace: return 4
        case .document: return 5
        }
    }

    /// Merge independently-proven detail. Cannot rewrite owning app/process/surface.
    /// PIN: nil = contradiction; CAS abstains.
    private static func merging(
        _ proposed: SourceScope, into current: SourceScope
    ) -> SourceScope? {
        func agrees<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
            lhs == nil || rhs == nil || lhs == rhs
        }
        guard agrees(proposed.deviceID, current.deviceID),
              agrees(proposed.applicationID, current.applicationID),
              agrees(proposed.processID, current.processID),
              agrees(proposed.processEpoch, current.processEpoch),
              agrees(proposed.activationSequence, current.activationSequence),
              agrees(proposed.windowID, current.windowID),
              agrees(proposed.workspaceID, current.workspaceID),
              agrees(proposed.projectID, current.projectID),
              agrees(proposed.documentID, current.documentID),
              agrees(proposed.surfaceID, current.surfaceID)
        else { return nil }

        var merged = current
        if let value = proposed.deviceID { merged.deviceID = value }
        if let value = proposed.applicationID { merged.applicationID = value }
        if let value = proposed.processID { merged.processID = value }
        if let value = proposed.processEpoch { merged.processEpoch = value }
        if let value = proposed.activationSequence { merged.activationSequence = value }
        if let value = proposed.windowID { merged.windowID = value }
        if let value = proposed.workspaceID { merged.workspaceID = value }
        if let value = proposed.projectID { merged.projectID = value }
        if let value = proposed.documentID { merged.documentID = value }
        if let value = proposed.surfaceID { merged.surfaceID = value }
        return merged
    }

    private static func pruneSelectionMutations(
        _ state: inout SelectionState, at now: Date
    ) {
        if state.recentClaimedHandoff?.isFresh(at: now) != true {
            state.recentClaimedHandoff = nil
        }
        state.sourceMutationAt = state.sourceMutationAt.filter {
            now.timeIntervalSince($0.value) <= selectionMutationRetention
        }
        state.processMutationAt = state.processMutationAt.filter {
            now.timeIntervalSince($0.value) <= selectionMutationRetention
        }
        // DeliveredSelection is semantic, not a watermark. Persists for the process session.
        // PIN: rearm = exact-source clear + later exact capture, or process teardown.
    }

    /// Prompt/debugger projection of the raw packet. Polls cannot compete here.
    private static func selectionFact(from handoff: AmbientSelectionHandoff) -> AmbientFact {
        AmbientFact(
            attention: handoff.attention,
            // Lane travels with the fact. Without it the highlight keys as the shared `.applications` lane.
            application: handoff.application,
            slot: .selection,
            content: handoff.text,
            surroundingText: handoff.surroundingText,
            subject: handoff.subject,
            applicationID: handoff.applicationID,
            // Raw AX range belongs to the emitting element. Body bounds come from enrichment only.
            bounds: handoff.documentBounds,
            documentTotal: handoff.documentTotal,
            anchor: .selection,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: handoff.capturedAt,
            freshFor: AmbientSelectionHandoff.handoffFreshFor)
    }

    private static func selectionWorld(
        from handoff: AmbientSelectionHandoff
    ) -> AmbientWorld.Snapshot {
        AmbientWorld.Snapshot(
            tier: .selection,
            attention: handoff.attention,
            subject: handoff.subject,
            applicationID: handoff.applicationID,
            key: AmbientKey(attention: handoff.attention, application: handoff.application, slot: .selection),
            selectedText: handoff.text,
            surroundingText: handoff.surroundingText,
            selectionEditability: handoff.editability,
            selectionSourceEvidence: handoff.sourceEvidence,
            selectionPayloadRecovery: handoff.payloadRecovery,
            capturedAt: handoff.capturedAt,
            freshFor: AmbientSelectionHandoff.handoffFreshFor)
    }

    /// Disable/quit teardown invalidates the source packet. Document refresh never calls this.
    private func discardSelection(attention: AmbientAttention, at now: Date = Date()) {
        let removed = selectionStateBox.withLock { state -> AmbientSelectionHandoff? in
            Self.pruneSelectionMutations(&state, at: now)
            state.deliveredSelections = state.deliveredSelections.compactMapValues { tombstones in
                let retained = tombstones.filter { $0.attention != attention }
                return retained.isEmpty ? nil : retained
            }
            if state.recentClaimedHandoff?.attention == attention {
                state.recentClaimedHandoff = nil
            }
            guard let handoff = state.handoff, handoff.attention == attention else { return nil }
            state.sourceMutationAt[SelectionSource(handoff)] = now
            state.handoff = nil
            return handoff
        }
        guard let removed else { return }
        worldBox.withLock { snapshot in
            guard snapshot?.tier == .selection,
                  snapshot?.applicationID == removed.applicationID
            else { return }
            snapshot = nil
        }
    }

    public static func ordered(_ lhs: AmbientFact, _ rhs: AmbientFact) -> Bool {
        // Place order: built-ins keep positions; registrations sort after, in roster order.
        if lhs.place.order != rhs.place.order { return lhs.place.order < rhs.place.order }
        if lhs.slot.order != rhs.slot.order { return lhs.slot.order < rhs.slot.order }
        return lhs.key.id < rhs.key.id
    }

    private static func prune(_ facts: inout [AmbientKey: AmbientFact], at now: Date) {
        for (key, fact) in Array(facts) where fact.isExpired(at: now) { facts[key] = nil }
    }

    /// Newest `namedReadCap` reads per lane survive; oldest drop. Keyed on `isRead`.
    /// PIN: lane, not world — apps sharing `.applications` must not share one budget.
    private static func capNamedReads(
        _ facts: inout [AmbientKey: AmbientFact],
        attention: AmbientAttention,
        application: String?
    ) {
        let reads = facts.values
            .filter { $0.attention == attention && $0.application == application && $0.slot.isRead }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard reads.count > namedReadCap else { return }
        for fact in reads.dropFirst(namedReadCap) { facts[fact.key] = nil }
    }

    /// Publish held facts to the observer. None today. OUT: AmbientObserving.
    private func emit(_ facts: [AmbientFact]) {
        guard let observer = observerBox.withLock({ $0 }) else { return }
        Task { for fact in facts { await observer.observed(fact) } }
    }
}
