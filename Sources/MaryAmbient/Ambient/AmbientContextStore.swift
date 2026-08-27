// Short-term, in-memory awareness for the current machine and conversation.
// Live perception and reads stay here; Totem owns durable retrieval.
//
// THE STORE'S WIRINGS ARE TIERED, AX AT THE TOP:
//   tier 0 — the SURFACE (`AmbientSurface`, `noteSurface` in
//            `AmbientContextStore+Surface.swift`): the accessibility
//            engine's foundation — what is actually on screen, retrieved
//            first, one per family lane, dropped (never degraded) at
//            expiry.
//   tier 1 — FACTS (`register`/`replacePerceived`): the supporting details
//            each application's own channels add on top — document bodies,
//            word counts, git, binders — held with age and honest
//            degradation.
//   tier 2 — SELECTION/ATTENTION (`recordSelection`/`noteAttention`):
//            source-owned interaction packets, never inferred from a poll.
// Readers present in that order: the surface is the ground the details
// stand on.

import CryptoKit
import MaryFoundation
import Foundation
import os

/// Mutable-once holder used only to publish a route after classifiers run
/// inside an already-frozen turn. A reference is required because TaskLocal
/// values themselves cannot be reassigned midway through `runTurnBody`.
public final class AmbientRouteTurnState: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock<AmbientRoute?>(initialState: nil)

    public init() {}

    public func note(_ route: AmbientRoute) { box.withLock { $0 = route } }
    public func current() -> AmbientRoute? { box.withLock { $0 } }
}

/// Every overlapping request gets its own route holder. An explicit nil in a
/// scoped holder means "this turn has not routed yet," never "fall back to a
/// different turn's process-global debugger snapshot."
public enum AmbientRouteTurnContext {
    @TaskLocal public static var state: AmbientRouteTurnState?
}

/// A normalized form of awareness a support plugin can provide.
public enum AmbientSense: String, CaseIterable, Hashable, Sendable, Codable {
    case workspace
    case selection
    case hover
}

public enum AmbientAttentionTier: Int, Sendable, Equatable, CaseIterable, Codable {
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

public struct AmbientAttention: Sendable, Equatable {
    public var tier: AmbientAttentionTier
    public var world: AmbientWorld
    public var subject: String?
    /// Exact source application for a direct selection. Workspace worlds are
    /// already represented by their plugin; the generic other-apps world
    /// needs this to bring typing back to the same frontmost text surface.
    public var applicationID: String?
    public var key: AmbientKey?
    /// The exact direct text, when this attention signal came from a selection.
    public var selectedText: String?
    /// Nearby text that may inform a transformation but is never its target.
    public var surroundingText: String?
    /// A direct selection's source mutation capability. It is nil for
    /// ordinary activation/hover attention, whose transport has no text
    /// surface to write into.
    public var selectionEditability: AmbientSelectionEditability?
    /// How directly Accessibility identified the text element for a direct
    /// selection. A canvas-descendant discovery is enough to discuss the
    /// words, but it is deliberately not enough to promise an in-place
    /// replacement later: the live focused surface may be the canvas rather
    /// than the descendant that supplied the text.
    public var selectionSourceEvidence: AmbientSelectionSourceEvidence?
    /// Whether a specialist recovered the payload outside the AX source
    /// element. Such text remains an exact conversational referent, but this
    /// provenance must stay visible to routing so it cannot become an
    /// in-place replacement target.
    public var selectionPayloadRecovery: AmbientSelectionPayloadRecovery?
    public var capturedAt: Date
    public var freshFor: TimeInterval

    public init(
        tier: AmbientAttentionTier,
        world: AmbientWorld,
        subject: String? = nil,
        applicationID: String? = nil,
        key: AmbientKey? = nil,
        selectedText: String? = nil,
        surroundingText: String? = nil,
        selectionEditability: AmbientSelectionEditability? = nil,
        selectionSourceEvidence: AmbientSelectionSourceEvidence? = nil,
        selectionPayloadRecovery: AmbientSelectionPayloadRecovery? = nil,
        capturedAt: Date = Date(),
        freshFor: TimeInterval? = nil
    ) {
        self.tier = tier
        self.world = world
        self.subject = subject
        self.applicationID = applicationID
        self.key = key
        self.selectedText = selectedText
        self.surroundingText = surroundingText
        self.selectionEditability = selectionEditability
        self.selectionSourceEvidence = selectionSourceEvidence
        self.selectionPayloadRecovery = selectionPayloadRecovery
        self.capturedAt = capturedAt
        self.freshFor = freshFor ?? tier.freshFor
    }

    public init(selection fact: AmbientFact) {
        self.init(
            tier: .selection,
            world: fact.world,
            subject: fact.subject,
            applicationID: fact.applicationID,
            key: fact.key,
            selectedText: fact.content,
            surroundingText: fact.surroundingText,
            selectionEditability: nil,
            selectionSourceEvidence: nil,
            selectionPayloadRecovery: nil,
            capturedAt: fact.capturedAt,
            freshFor: fact.freshFor)
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= freshFor
    }

    public func matches(_ fact: AmbientFact) -> Bool {
        if let key { return fact.key == key }
        guard fact.world == world else { return false }
        return subject == nil || fact.subject == subject
    }

    public var isDirectReference: Bool { tier == .selection }
}

/// Process-wide, lock-protected short-term awareness.
public final class AmbientContextStore: @unchecked Sendable {

    public static let shared = AmbientContextStore()

    /// How many named reads ONE world may hold. The retention policy's
    /// backstop: `(world, namedRead(phrase))` is the only key whose second
    /// half is unbounded, so this is where "nothing accumulates unboundedly"
    /// is actually enforced. Oldest goes first.
    public static let namedReadCap = 4

    private let box = OSAllocatedUnfairLock<[AmbientKey: AmbientFact]>(initialState: [:])
    /// TIER 0 — one surface per family lane (see the file header and
    /// `AmbientContextStore+Surface.swift`, which owns every access).
    /// `internal` so the extension file and `@testable` reach it.
    let surfaceBox =
        OSAllocatedUnfairLock<[AmbientPlace: AmbientSurface]>(initialState: [:])
    /// The focus arbiter's current lead — held as a PLACE, because the lead
    /// can be a registered application riding `.applications`, and a world alone
    /// cannot say which one. World callers read `place.world`, unchanged.
    private let leadBox =
        OSAllocatedUnfairLock<(place: AmbientPlace, at: Date)?>(initialState: nil)
    /// The utterance currently being answered.
    private let utteranceBox = OSAllocatedUnfairLock<String>(initialState: "")
    /// The resolved container for the active turn.
    private let referenceBox = OSAllocatedUnfairLock<ReferenceDecision>(initialState: .none)
    /// The route shared by retrieval and prompt assembly.
    private let routeBox = OSAllocatedUnfairLock<AmbientRoute?>(initialState: nil)
    private let attentionBox = OSAllocatedUnfairLock<AmbientAttention?>(initialState: nil)
    /// The one canonical source-owned highlight.  Its projection into a fact
    /// and attention is derived at read time; document watchers never own a
    /// second copy of selection state. Source and process mutation watermarks
    /// outlive a clear briefly so a delayed AX read cannot resurrect what the
    /// user just deselected from another surface in the same application.
    private struct SelectionState {
        var handoff: AmbientSelectionHandoff?
        /// The single selection most recently handed to a turn. It is kept
        /// only for the packet's normal freshness window so an immediate
        /// conversational follow-up can still mean “the part I highlighted.”
        /// This is not standing ambient state: ordinary turns cannot see it,
        /// a new source packet replaces it, and source lifecycle clears it.
        var recentClaimedHandoff: AmbientSelectionHandoff?
        var sourceMutationAt: [SelectionSource: Date] = [:]
        /// A highlight is an input handoff, not standing ambient memory. Once
        /// a turn claims a packet, repeated AX polls/handoffs of that unchanged
        /// selection must not arm unrelated later turns. This is a
        /// process-session semantic history rather than per AX object: canvas
        /// apps may expose old selections through different descendants later.
        /// An exact-source caret clear opens a one-selection rearm fence;
        /// accepting a newer h2 must not forget h1.
        var deliveredSelections: [SelectionProcess: [DeliveredSelection]] = [:]
        /// A process-wide ordering watermark complements the intentionally
        /// narrow source-surface fingerprint. A title/control caret must not
        /// clear a body highlight, but a late read from that other surface
        /// must not revive after any selection in this process was accepted,
        /// explicitly cleared, or claimed by a turn.
        var processMutationAt: [SelectionProcess: Date] = [:]
    }
    private let selectionStateBox = OSAllocatedUnfairLock<SelectionState>(
        initialState: .init())
    private static let selectionMutationRetention: TimeInterval = 60
    private let observerBox =
        OSAllocatedUnfairLock<(any AmbientObserving)?>(initialState: nil)

    // NO DURABLE-LEARNING SINKS YET. Bonnie published held facts onward to
    // three idle-gated indexers — an observation sink, a project indexer and
    // a unit indexer — which together are the behavioural-corpus lane. That
    // lane is deferred, and the seam it attaches to is `AmbientObserving`
    // below rather than three boxes: one protocol, installed once, is what a
    // later stage re-attaches.

    /// Where held facts publish as embeddable records, so "the thing about
    /// the deploy" can rank against what is actually held. Facts carry no
    /// capabilities — they are evidence, never mutation targets.
    private let elementIndexStore: AmbientElementIndexStore

    public init(elementIndexStore: AmbientElementIndexStore? = nil) {
        self.elementIndexStore = elementIndexStore ?? AmbientElementIndexStore()
    }

    /// The gate's partition for one world's facts.
    public static func scope(world: AmbientWorld) -> AmbientElementScope {
        AmbientElementScope(place: .lane(world), key: world.rawValue)
    }

    /// Republish one world's facts. Outside the fact lock, like every
    /// publisher — the store vectorizes.
    private func publishElements(worlds: Set<AmbientWorld>, at now: Date) {
        for world in worlds {
            elementIndexStore.noteElements(
                AmbientFactRule.records(
                    for: facts(world: world, at: now),
                    scope: Self.scope(world: world)),
                scope: Self.scope(world: world))
        }
    }

    /// A world's held facts, ranked by relevancy to a spoken phrase.
    public func rankedFacts(
        matching phrase: String, world: AmbientWorld
    ) -> [RankedAmbientElement] {
        AmbientReferenceGate.rank(
            phrase: phrase,
            scope: Self.scope(world: world),
            store: elementIndexStore)
    }

    // MARK: - Writers

    /// Register a fact. A superseding write REPLACES its slot; nothing
    /// accumulates. Expired facts are pruned on the way through, so the store
    /// stays bounded without a timer. Direct selections are deliberately not
    /// accepted here: an `AmbientFact` is already clipped/projected and lacks
    /// the source process and capture ordering that make a handoff safe. Use
    /// `recordSelection(_:)` for that one interaction type.
    public func register(_ fact: AmbientFact, at now: Date = Date()) {
        guard fact.slot != .selection else { return }
        box.withLock { facts in
            Self.prune(&facts, at: now)
            facts[fact.key] = fact
            Self.capNamedReads(&facts, world: fact.world, application: fact.application)
        }
        publishElements(worlds: [fact.world], at: now)
    }

    public func register(_ facts: [AmbientFact], at now: Date = Date()) {
        let nonSelectionFacts = facts.filter { $0.slot != .selection }
        guard !nonSelectionFacts.isEmpty else { return }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            for fact in nonSelectionFacts { stored[fact.key] = fact }
            // ONE PASS PER LANE. A batch can carry facts for several
            // registered applications sharing `.applications`, and each owns its
            // own read budget — see `capNamedReads`.
            var lanes: Set<AmbientPlace> = []
            for fact in nonSelectionFacts { lanes.insert(fact.place) }
            for lane in lanes {
                Self.capNamedReads(&stored, world: lane.world, application: lane.application)
            }
        }
        publishElements(worlds: Set(nonSelectionFacts.map(\.world)), at: now)
    }

    /// Replace a world's document/perception slots wholesale — one poll, one
    /// truth. Direct selection deliberately does not travel through this
    /// method: it is a source-owned interaction packet, not evidence inferred
    /// from a document poll. Named reads are untouched: they belong to the
    /// conversation, not to the poll.
    /// `application` SCOPES THE WIPE TO ONE LANE. `.applications` is one world
    /// shared by every registered application, so a world-wide clear would let
    /// Sketch's poll erase what Mary knows about Keynote. Nil is every
    /// built-in world's lane and behaves exactly as it always has.
    public func replacePerceived(
        world: AmbientWorld,
        application: String? = nil,
        with facts: [AmbientFact],
        at now: Date = Date()
    ) {
        // A document/perception poll has no authority to reconstruct an
        // interaction. Reject a selection fact even if an old caller tries to
        // smuggle one through this broad replacement API.
        let nonSelectionFacts = facts.filter { $0.slot != .selection }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            // `Array(...)` on purpose: iterating a live `keys` view while
            // mutating the dictionary is the kind of aliasing that works until
            // it doesn't. The snapshot costs nothing at these sizes.
            for key in Array(stored.keys) where key.world == world
                && key.application == application
                && key.slot.isPerceived {
                stored[key] = nil
            }
            for fact in nonSelectionFacts where fact.slot.isPerceived {
                stored[fact.key] = fact
            }
        }
        emit(nonSelectionFacts)
        publishElements(worlds: [world], at: now)
    }

    /// A representation went dark (plugin disabled, watcher restarted, or its
    /// document channel closed). Perceived facts go; a READ survives — the
    /// user asked for it, and the document closing does not unmake that read.
    ///
    /// A direct selection is deliberately NOT part of this teardown. It is
    /// source-app input, not a fact the representation inferred; the generic
    /// selection ability may still own the exact same source after a plugin
    /// unloads. Explicit deselection, source termination, expiry, or the full
    /// `forget(world:)` path invalidates it instead.
    ///
    /// LANE-SCOPED BY CONSTRUCTION: the place IS the lane, so a registered
    /// application's teardown can never erase what a sibling on the same host
    /// world still perceives.
    public func forgetPerceived(place: AmbientPlace) {
        box.withLock { stored in
            for key in Array(stored.keys)
            where key.place == place && key.slot.isPerceived {
                stored[key] = nil
            }
        }
        attentionBox.withLock { attention in
            guard attention?.world == place.world,
                  attention?.tier != .selection
            else { return }
            attention = nil
        }
    }

    /// WORLD-WIDE teardown — every lane in the world goes, including every
    /// registered application riding it. Deliberately NOT a
    /// `forget(place:)` wrapper, and deliberately world-typed for good: a
    /// place names ONE lane, and this method's callers (disable/quit paths,
    /// test isolation) mean the whole world — a legitimate cross-lane
    /// operation, the same species of query as `facts(world:)`. The
    /// world-typed signature IS the roster/lane distinction: you cannot
    /// hand it a lane, so you cannot accidentally tear down a sibling's.
    public func forget(world: AmbientWorld) {
        box.withLock { stored in
            for key in Array(stored.keys) where key.world == world { stored[key] = nil }
        }
        attentionBox.withLock { attention in
            guard attention?.world == world else { return }
            attention = nil
        }
        discardSelection(world: world)
    }

    public func forget(key: AmbientKey) {
        box.withLock { $0[key] = nil }
        attentionBox.withLock { attention in
            guard attention?.key == key else { return }
            attention = nil
        }
    }

    /// THE TURN LOOP'S WRITE-BACK: what was spoken about a fact. Matches by
    /// CONTENT containment because the passage that reached the voice is the
    /// fact's own text, rendered — the brain never has to learn the store's
    /// keys to report back.
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

    /// The lead is a COPY of tracker-derived focus, and a copy asserting
    /// longer than its source is the stale-lead bug in a second wardrobe:
    /// the tracker's own signals decay at `WorkspaceFocusTracker`'s horizon,
    /// so the persisted lead observes the same one.
    ///
    /// AND IT IS THE *LEAD* HORIZON, NOT THE SIGNAL HORIZON. Those were the
    /// same 20 minutes, and they are not the same claim. `signalHorizon`
    /// bounds an OBSERVATION — "the user was last seen in a writing app" —
    /// and its own comment defends the generosity correctly: reading a long
    /// document without touching the keyboard is still working in it. A LEAD
    /// asserts something far stronger — "this is what the turn is about" —
    /// and it outlived the evidence for it by fifteen minutes.
    ///
    /// THE FAILURE THIS FIXES (live, and named three times in this tree's own
    /// comments — "'led: Xcode' — the incident"): the badge read `led: Xcode ·
    /// workspace` on a turn that looked at a YouTube video in Chrome, and the
    /// lead is not only a badge — it reaches the prompt and grounds the
    /// answer. This copy is read one turn BEHIND its writer (the route reads
    /// it before the prompt providers run), so a coding-led turn's lead stands
    /// over every later turn until it decays.
    ///
    /// Aligned to `FocusSignal.coActiveHorizon` rather than a new number: a
    /// lead that no longer has co-active evidence beside it is exactly a lead
    /// that has stopped earning the claim, and that bound already has a name.
    public static let leadHorizon: TimeInterval = FocusSignal.coActiveHorizon

    /// Which PLACE the focus arbiter gave the lead to this turn — the
    /// canonical writer, and since M4 the only one.
    public func noteLead(place: AmbientPlace?) {
        leadBox.withLock { $0 = place.map { ($0, Date()) } }
    }

    /// The canonical read: the lead as a place, decayed at `leadHorizon` —
    /// the copy must not assert longer than its tracker-derived source.
    public func leadPlace(at now: Date = Date()) -> AmbientPlace? {
        leadBox.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.leadHorizon
            else { return nil }
            return held.place
        }
    }

    /// The utterance the current turn is answering — the situational moment
    /// the budget policy ranks against.
    public func noteUtterance(_ text: String) {
        utteranceBox.withLock { $0 = text }
    }

    public func utterance() -> String {
        utteranceBox.withLock { $0 }
    }

    /// WHICH CONTAINER THIS TURN MEANS — the third side channel, written by the
    /// turn loop once and read by every seam that needs to know.
    ///
    /// It exists for the reason the two above do: four different places derive
    /// "which document" (the targeted read, the passage locate, the body
    /// reader, the Skill bindings' own parameters), they fire at four different times
    /// in two different lanes, and four independent derivations of one answer is
    /// exactly how `document 1` and the front window came to disagree. Resolve
    /// once, publish, read everywhere.
    ///
    /// NIL IS THE COMMON VALUE and it means "nobody named a container" — every
    /// reader then falls back to whatever it did before, unchanged.
    public func noteReference(_ decision: ReferenceDecision) {
        referenceBox.withLock { $0 = decision }
    }

    /// The whole decision, including a refusal.
    public func reference() -> ReferenceDecision {
        referenceBox.withLock { $0 }
    }

    /// Just the container, for callers that only want "which one". A refusal
    /// reads as nil here, so nothing silently proceeds on one.
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

    /// WHERE PERCEPTION PUBLISHES ONWARD, when something is listening.
    ///
    /// One seam rather than the three separate sinks Bonnie grew (an
    /// observation bridge, a project indexer, a unit indexer), because they
    /// were installed together, gated together and deferred together — three
    /// boxes describing one decision. Nothing implements this yet; the
    /// behavioural-corpus lane is a later stage, and perception is fully
    /// usable without it.
    ///
    /// WHAT MAY CROSS, whenever something does implement it: structure only —
    /// never document text, titles, selections, or the contents of anything
    /// the user is working on. A durable index of what the user DOES is a
    /// different thing from a copy of what they wrote, and the moment the
    /// second rides on the first there is no way to offer one without the
    /// other.
    public protocol AmbientObserving: Sendable {
        func observed(_ fact: AmbientFact) async
    }

    public func setObserver(_ observer: (any AmbientObserving)?) {
        observerBox.withLock { $0 = observer }
    }

    // MARK: - Direct selection handoff

    /// Publish the one canonical selection for the current interaction.
    ///
    /// A source app supplies this while it still owns the selection. The raw
    /// handoff is the only stored form; the shorter ambient fact and direct
    /// attention are projections, not competing writers. A source poll stamps
    /// `capturedAt` before its AX read begins, and a per-process mutation
    /// watermark rejects a delayed result after an observer event or clear.
    /// `at` is the receipt clock (normally `Date()`); ordering always uses the
    /// packet's own `capturedAt`, so a slow AX read cannot look newer merely
    /// because it completed later.
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
                // A generic AX poll may complete just after an application
                // adapter atomically resolved the same selected value to a
                // project/document. It contributes no new interaction and
                // must not erase that richer scope merely because its packet
                // has a later receipt. A genuinely different value remains a
                // new interaction and is ordered normally.
                if Self.isScopeDowngrade(handoff, of: current, at: now) {
                    return false
                }
                // A direct event/handoff named one concrete AX surface. A
                // lower-confidence periodic scan can still find an old
                // selection retained by a different child under the same
                // Pages process. It cannot prove that inactive child became
                // the user's new interaction, so it may not replace the
                // direct source packet. This is source-evidence ordering, not
                // a document/title heuristic; a direct event or a poll from
                // the same surface can still advance the selection normally.
                if Self.isCrossSurfaceFallback(
                    handoff, weakerThan: current, at: now) {
                    return false
                }
                // Repeated reports of the same source interaction do not
                // renew its lease. This makes duplicate deactivation events
                // and fallback probes idempotent rather than letting a stale
                // highlight survive indefinitely.
                if current.world == handoff.world,
                   current.applicationID == handoff.applicationID,
                   current.processID == handoff.processID,
                   current.sourceSurfaceID == handoff.sourceSurfaceID,
                   current.text == handoff.text,
                   current.range == handoff.range,
                   // Xcode can expose the same words at the same character
                   // range in two files through one process and no AX surface
                   // id. Mutually-proven workspace/project/document identity
                   // is therefore part of the interaction identity. A missing
                   // field remains conservative rather than manufacturing a
                   // distinction the adapter did not prove.
                   !ProvenSelectionScope(current.scope)
                    .isDistinct(from: handoff.scope),
                   // An exact observer/handoff may upgrade an identical
                   // generic sample's provenance. The reverse direction is a
                   // duplicate and must not renew the packet.
                   !(handoff.sourceEvidence.rank > current.sourceEvidence.rank),
                   current.isFresh(at: now) {
                    return false
                }
            }
            // A source poll, lifecycle handoff, or queued AX callback may keep
            // seeing the physical highlight long after Mary used it,
            // including through a different descendant in a canvas app. AX
            // callbacks have no event timestamp, so even a named selected-text
            // notification cannot prove it was a fresh same-range gesture
            // after an app reactivates. An exact source clear (or a semantically
            // distinct selection) is the causal boundary that may rearm it.
            if var delivered = state.deliveredSelections[process] {
                let matchingIndices = delivered.indices.filter {
                    delivered[$0].matches(handoff)
                }
                if !matchingIndices.isEmpty {
                    // A same-range/text h1 cannot be distinguished from a
                    // queued old AX callback by receipt time alone. A caret
                    // from the exact source surface is the causal fence that
                    // permits one later exact capture to mean "reselected".
                    // A discovered sibling (or an AX surface merely sharing a
                    // process) stays tombstoned after that clear.
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
            // Surface identity keeps a title caret from clearing a body
            // highlight. Ordering must still be process-wide, otherwise a
            // slow AX scan of that other surface can republish a stale
            // selection after this one has become authoritative.
            state.processMutationAt[process] = max(
                state.processMutationAt[process] ?? .distantPast, handoff.capturedAt)
            return true
        }
        guard accepted else { return false }
        box.withLock { stored in
            Self.prune(&stored, at: now)
            // Compatibility writers from pre-handoff watchers may still have
            // left a selection fact behind. The canonical packet projects the
            // only one that may participate in this interaction.
            for key in Array(stored.keys) where key.slot == .selection {
                stored[key] = nil
            }
        }
        attentionBox.withLock { attention in
            guard attention?.tier == .selection else { return }
            attention = nil
        }
        emit([Self.selectionFact(from: handoff)])
        return true
    }

    /// An explicit empty-selection event may clear only the source that set
    /// the handoff. A focus change, a different app's poll, or an unparseable
    /// nonempty AX range is intentionally not a deselection event.
    public func clearSelection(
        applicationID: String,
        processID: Int32? = nil,
        sourceSurfaceID: UInt? = nil,
        /// Only lifecycle teardown for a terminated source process may clear
        /// every AX surface under that PID. Observer/poll caret events leave
        /// this false and therefore fail closed across unknown identities.
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
            // A clear is an explicit source mutation even when it cannot
            // remove the current packet (for example, a caret in another
            // Pages surface). Advance the process watermark so an AX read
            // started before this event cannot arrive later and revive that
            // older surface's selection.
            if let process {
                state.processMutationAt[process] = max(
                    state.processMutationAt[process] ?? .distantPast, capturedAt)
            }
            // Preserve a source-local watermark even if another application
            // currently owns the global handoff. That prevents a delayed poll
            // from this source from stealing an older selection back later.
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
                // A caret only opens a rearm fence for the exact AX surface
                // that emitted it. It does not erase the semantic tombstone:
                // a Pages/TextEdit sibling can retain the old h1 and report it
                // after this clear. Only a later exact capture from this
                // cleared source may consume the fence.
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
        attentionBox.withLock { attention in
            guard attention?.applicationID == applicationID,
                  attention?.tier == .selection
            else { return }
            attention = nil
        }
    }

    /// An unclaimed source selection is a handoff to Mary, not standing
    /// context across ordinary app switches. When a different external app
    /// becomes active, revoke the pending packet and advance its source/process
    /// ordering fences so an AX read that began before that activation cannot
    /// revive it afterwards. A missing application or process id is
    /// conservative: an unknown external activation cannot prove the old
    /// source is still the user's direct referent.
    ///
    /// The caller deliberately invokes this only for non-Mary activations.
    /// A Mary activation is the handoff destination and must leave the raw
    /// packet available for the imminent turn snapshot.
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
        attentionBox.withLock { attention in
            guard attention?.tier == .selection,
                  attention?.applicationID == removed.applicationID
            else { return }
            attention = nil
        }
        return true
    }

    /// The raw handoff, still exact and never prompt-clipped. A plugin may use
    /// it to enrich its own document snapshot only when the source matches.
    public func selectionHandoff(
        world: AmbientWorld? = nil,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        if let snapshot = AmbientSelectionTurnContext.snapshot {
            guard let handoff = snapshot.handoff,
                  world == nil || handoff.world == world
            else { return nil }
            return handoff
        }
        return currentSelectionHandoff(world: world, at: now)
    }

    /// The one selection later prompt and execution seams may consume. A raw
    /// handoff can remain available for diagnostics and source enrichment even
    /// when the request named a conflicting application; this accessor applies
    /// the immutable route before returning its bytes.
    public func routedSelectionHandoff(
        world: AmbientWorld? = nil,
        requiringWritingTarget: Bool = false,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        guard let route = route(),
              !requiringWritingTarget || route.writingTarget == .selection,
              let handoff = selectionHandoff(world: world, at: now),
              route.admitsSelectionHandoff(handoff)
        else { return nil }
        return handoff
    }

    /// The latest not-yet-claimed process-wide packet, deliberately ignoring
    /// a turn-local snapshot. Background representations use this while
    /// publishing their own persistent context; once a turn claims the packet
    /// it is intentionally unavailable here, so a slow poll cannot publish an
    /// old anchor for later turns.
    public func liveSelectionHandoff(
        world: AmbientWorld? = nil,
        at now: Date = Date()
    ) -> AmbientSelectionHandoff? {
        currentSelectionHandoff(world: world, at: now)
    }

    private func currentSelectionHandoff(
        world: AmbientWorld? = nil,
        application: String? = nil,
        at now: Date
    ) -> AmbientSelectionHandoff? {
        selectionStateBox.withLock { state in
            Self.pruneSelectionMutations(&state, at: now)
            guard let handoff = state.handoff, handoff.isFresh(at: now) else {
                state.handoff = nil
                return nil
            }
            guard world == nil || handoff.world == world else { return nil }
            // A LANE ASKED FOR IS A LANE REQUIRED. Nil means "the world's own",
            // not "any" — otherwise asking for Sketch's selection inside
            // `.applications` would hand back whichever application polled last,
            // which is the collision the lane exists to end.
            guard application == nil || handoff.application == application else { return nil }
            return handoff
        }
    }

    /// Atomically claim the selection that will be bound task-locally to one
    /// turn. A highlight is a one-request handoff, not standing context: after
    /// this returns, the process-wide packet is gone and only the task-local
    /// caller can see it. The delivered semantic ledger remains until its
    /// source explicitly clears and a later exact capture crosses that rearm
    /// fence, or the source terminates. Time alone must not re-arm a
    /// still-visible highlight through a slow poll or queued callback.
    ///
    /// There is intentionally no global "release". An older cancelled turn
    /// can never unseal a newer selection or inject its highlight into a later
    /// request.
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
            // A direct reselect may have removed this semantic entry; if it
            // did not, replace only the equivalent record rather than letting
            // duplicate claims grow the semantic ledger.
            delivered.removeAll { $0.matches(handoff) }
            delivered.append(DeliveredSelection(
                handoff, source: source, claimedAt: now))
            state.deliveredSelections[process] = delivered
            // A delayed AX read that began before this turn must not arrive
            // afterward and republish an older value under a different packet
            // id or AX surface. New captures begun after this point remain
            // eligible.
            state.sourceMutationAt[source] = max(
                state.sourceMutationAt[source] ?? .distantPast, now)
            state.processMutationAt[process] = max(
                state.processMutationAt[process] ?? .distantPast, now)
            state.recentClaimedHandoff = handoff
            state.handoff = nil
            return handoff
        }
    }

    /// Enrich the current source packet only if it is still the exact capture
    /// a plugin inspected. This is the compare-and-set seam that lets Pages
    /// attach a validated document name/range after a slow body read without
    /// ever pairing it with a newer TextEdit/Pages selection.
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

    public func noteAttention(_ incoming: AmbientAttention, at now: Date = Date()) {
        // A direct selection has one authoritative entry point:
        // `recordSelection(_:)`. Accepting a standalone selection attention
        // here would rebuild the duplicate-state path this store eliminated.
        guard incoming.tier != .selection else { return }
        guard incoming.isFresh(at: now) else { return }
        attentionBox.withLock { current in
            guard let existing = current, existing.isFresh(at: now) else {
                current = incoming
                return
            }
            if incoming.tier.rawValue >= existing.tier.rawValue {
                current = incoming
            }
        }
        emit(facts(world: incoming.world, at: now))
    }

    public func attention(at now: Date = Date()) -> AmbientAttention? {
        if let snapshot = AmbientSelectionTurnContext.snapshot {
            // The task-local scope freezes only direct selection. A turn that
            // began without one must still retain ordinary hover/activation
            // attention; it just cannot see a new highlight that arrives
            // halfway through generation.
            if let handoff = snapshot.handoff {
                return Self.selectionAttention(from: handoff)
            }
        } else if let handoff = currentSelectionHandoff(at: now) {
            return Self.selectionAttention(from: handoff)
        }
        return attentionBox.withLock { value -> AmbientAttention? in
            guard let value, value.isFresh(at: now) else {
                value = nil
                return nil
            }
            return value
        }
    }

    // MARK: - Readers

    /// Every live fact, in deterministic order (world, then slot, then key) —
    /// the prompt and the pane must be able to render the same list twice and
    /// get the same bytes.
    public func facts(at now: Date = Date()) -> [AmbientFact] {
        var live = box.withLock { stored -> [AmbientFact] in
            Self.prune(&stored, at: now)
            return Array(stored.values)
        }
        // A direct selection is projected from its source-owned packet rather
        // than persisted beside document facts.  In a turn-local scope, even
        // a newly-arrived live selection must not leak into this turn.
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

    /// EVERY lane in a world — for `.applications`, every registered
    /// application at once. Deliberately NOT `facts(place: .lane(world))`:
    /// that names the world's OWN lane and would drop every registered
    /// application's facts from the roster queries (`publishElements`,
    /// `noteAttention`'s emit) that mean the whole world. A world-wide query
    /// is a legitimate cross-lane operation, not a missing place overload —
    /// the world-typed signature is the name of that scope, permanently, the
    /// same way `forget(world:)` spells world-wide teardown.
    public func facts(world: AmbientWorld, at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { $0.world == world }
    }

    /// One LANE's facts. `facts(world:)` returns everything in a world, which
    /// for `.applications` is every registered application at once — right for a
    /// roster, wrong for "what is this application looking at".
    public func facts(place: AmbientPlace, at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { $0.place == place }
    }

    /// `application` NARROWS TO ONE LANE inside a world that holds several.
    /// Nil asks the world's own lane, which is every built-in world's and is
    /// what every existing caller means.
    public func fact(
        world: AmbientWorld,
        application: String? = nil,
        slot: AmbientSlot,
        at now: Date = Date()
    ) -> AmbientFact? {
        if slot == .selection {
            if let snapshot = AmbientSelectionTurnContext.snapshot {
                guard let handoff = snapshot.handoff,
                      handoff.world == world,
                      handoff.application == application
                else { return nil }
                return Self.selectionFact(from: handoff)
            }
            if let handoff = currentSelectionHandoff(
                world: world, application: application, at: now) {
                return Self.selectionFact(from: handoff)
            }
            return nil
        }
        return box.withLock { stored -> AmbientFact? in
            let fact = stored[AmbientKey(world: world, application: application, slot: slot)]
            guard let fact, !fact.isExpired(at: now) else { return nil }
            return fact
        }
    }

    /// The reads Mary is holding — the continuity surface, for the pane's
    /// `read:` rows and for anything that wants "what did she actually fetch".
    /// Reads ONLY: a standing digest is also non-perceived, and a caller
    /// asking "what did she fetch" must not be handed a line nobody asked for.
    public func reads(at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter(\.slot.isRead)
    }

    /// EVERYTHING WITH NO LIVE WINDOW BEHIND IT — held reads plus the standing
    /// digests of eyeless sources. The debugger's escape hatch: the pane joins
    /// facts to cards per WATCHED world, so a calendar fact joins no card at
    /// all. Without this query it would ride both prompts and appear nowhere
    /// on the pane, which is precisely the prompt/pane drift the store exists
    /// to end.
    public func unwindowed(at now: Date = Date()) -> [AmbientFact] {
        facts(at: now).filter { !$0.slot.isPerceived }
    }

    /// Reads registered at or after `date`. The turn loop's question, asked
    /// once per turn: did the read this lane just performed land somewhere, or
    /// reach nobody? (`ReadRoute.registered` vs `.discarded`.)
    public func reads(since date: Date, at now: Date = Date()) -> [AmbientFact] {
        reads(at: now).filter { $0.capturedAt >= date }
    }

    /// Test isolation — the process-wide box must never leak between suites
    /// (the ReadDeliveryLedger precedent).
    public func clear() {
        box.withLock { $0 = [:] }
        surfaceBox.withLock { $0 = [:] }
        leadBox.withLock { $0 = nil }
        utteranceBox.withLock { $0 = "" }
        routeBox.withLock { $0 = nil }
        attentionBox.withLock { $0 = nil }
        selectionStateBox.withLock { $0 = .init() }
        // The observer is NOT cleared here. A reset empties what Mary
        // currently believes; it does not detach what is listening, any more
        // than forgetting a conversation unsubscribes the transcript.
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

    /// A process-level tombstone after a packet has been handed to a turn.
    /// `id` and capture time are intentionally absent from its semantic
    /// identity: observer, handoff and poll paths can all report the same
    /// selection with different packet ids and receipt times. The original AX
    /// source remains only so a caret from an unrelated child cannot erase it.
    ///
    /// This is deliberately not count-evicted. Eviction would let an old h1
    /// become eligible again merely because the user selected eight newer
    /// things. The text is retained only as a SHA-256 identity, not as a
    /// growing archive of selected content; a digest collision fails closed
    /// by suppressing a possible new handoff rather than reviving old text.
    private struct DeliveredSelection {
        let source: SelectionSource
        let world: AmbientWorld
        let provenScope: ProvenSelectionScope
        let textIdentity: SelectionTextIdentity
        let range: Range<Int>?
        let claimedAt: Date
        /// A caret observed from this exact source after the handoff was used.
        /// It does not remove the tombstone; it only lets one later exact
        /// capture prove a deliberate reselect on that same AX element.
        var clearedAt: Date?

        public init(
            _ handoff: AmbientSelectionHandoff,
            source: SelectionSource,
            claimedAt: Date
        ) {
            self.source = source
            world = handoff.world
            provenScope = ProvenSelectionScope(handoff.scope)
            textIdentity = SelectionTextIdentity(handoff.text)
            range = handoff.range
            self.claimedAt = claimedAt
        }

        func matches(_ handoff: AmbientSelectionHandoff) -> Bool {
            guard world == handoff.world,
                  !provenScope.isDistinct(from: handoff.scope),
                  textIdentity.matches(handoff.text)
            else { return false }
            // AX range coordinates belong only to the element that emitted
            // them. A title/canvas sibling can use a different 0..<N coordinate
            // system for the same retained h1, so ranges distinguish repeated
            // words only when the exact source surface is the same. Across an
            // unknown/different surface, equal words are conservatively the
            // already-delivered interaction until an exact-source clear opens
            // its rearm fence.
            guard source == SelectionSource(handoff) else { return true }
            // AX may spell the same source selection through selected-text,
            // marker text, or a range-backed channel. When either path lacks a
            // range, absence is not proof of a new selection; only two known,
            // unequal same-surface ranges distinguish identical text.
            guard let range, let incomingRange = handoff.range else { return true }
            return range == incomingRange
        }
    }

    /// The document-bearing portion of selection identity. The source process
    /// is already the tombstone dictionary key, and AX surface identity is
    /// handled separately. These three fields distinguish editor buffers
    /// inside one process without treating an absent field as evidence of a
    /// different document. They are retained only as digests: a claimed
    /// selection must not turn project paths into a second ambient archive.
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

    /// Content-free identity for a delivered handoff. The raw text remains
    /// available only to the turn that claimed it; tombstones merely need to
    /// recognize the same physical selection when an AX tree reports it late.
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

    /// The source-identity guard for a direct capture versus a periodic scan
    /// of another AX surface. Both fingerprints must exist: a missing identity
    /// is not evidence that two elements differ, so ordinary time ordering
    /// applies in that case.
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

    /// Preserve a specialist's document/workspace resolution when a later
    /// generic provider merely repeats the same source value at a shallower
    /// scope. This is provider arbitration, never a focus or intent rule.
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

    /// Add independently-proven detail without allowing an enrichment to
    /// rewrite the source application/process/surface that owns the packet.
    /// Nil means the proposed scope contradicted the interaction and the CAS
    /// must abstain.
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
        // Unlike ordering watermarks, a delivered selection is semantic state:
        // an AX descendant can keep exposing the same old highlight for the
        // life of a document. It persists for the source process session;
        // only a matching exact-source clear plus a later exact capture, or
        // process teardown may rearm it. `DeliveredSelection` keeps only a
        // digest so this is not a retained-content archive.
    }

    /// The prompt/debugger projection of the raw source packet.  Keeping this
    /// construction here makes it impossible for a document poll to produce a
    /// competing direct-selection fact.
    private static func selectionFact(from handoff: AmbientSelectionHandoff) -> AmbientFact {
        AmbientFact(
            world: handoff.world,
            // THE LANE TRAVELS WITH THE FACT. Without it a registered
            // application's highlight rendered as "Applications · …" and keyed as
            // the shared lane, so the one thing the discriminator was added to
            // prevent — a selection attributed to the wrong application —
            // survived intact on the read path.
            application: handoff.application,
            slot: .selection,
            content: handoff.text,
            surroundingText: handoff.surroundingText,
            subject: handoff.subject,
            applicationID: handoff.applicationID,
            // Raw AX range coordinates belong to the emitting element. Only
            // an identity-checked enrichment may add body-validated bounds.
            bounds: handoff.documentBounds,
            documentTotal: handoff.documentTotal,
            anchor: .selection,
            provenance: .liveAX,
            registration: .perceived,
            capturedAt: handoff.capturedAt,
            freshFor: AmbientSelectionHandoff.handoffFreshFor)
    }

    private static func selectionAttention(
        from handoff: AmbientSelectionHandoff
    ) -> AmbientAttention {
        AmbientAttention(
            tier: .selection,
            world: handoff.world,
            subject: handoff.subject,
            applicationID: handoff.applicationID,
            key: AmbientKey(world: handoff.world, application: handoff.application, slot: .selection),
            selectedText: handoff.text,
            surroundingText: handoff.surroundingText,
            selectionEditability: handoff.editability,
            selectionSourceEvidence: handoff.sourceEvidence,
            selectionPayloadRecovery: handoff.payloadRecovery,
            capturedAt: handoff.capturedAt,
            freshFor: AmbientSelectionHandoff.handoffFreshFor)
    }

    /// Disable/quit teardown is the one lifecycle event that intentionally
    /// invalidates a source packet.  A normal document refresh never calls
    /// this: it only owns document facts.
    private func discardSelection(world: AmbientWorld, at now: Date = Date()) {
        let removed = selectionStateBox.withLock { state -> AmbientSelectionHandoff? in
            Self.pruneSelectionMutations(&state, at: now)
            state.deliveredSelections = state.deliveredSelections.compactMapValues { tombstones in
                let retained = tombstones.filter { $0.world != world }
                return retained.isEmpty ? nil : retained
            }
            if state.recentClaimedHandoff?.world == world {
                state.recentClaimedHandoff = nil
            }
            guard let handoff = state.handoff, handoff.world == world else { return nil }
            state.sourceMutationAt[SelectionSource(handoff)] = now
            state.handoff = nil
            return handoff
        }
        guard let removed else { return }
        attentionBox.withLock { attention in
            guard attention?.tier == .selection,
                  attention?.applicationID == removed.applicationID
            else { return }
            attention = nil
        }
    }

    public static func ordered(_ lhs: AmbientFact, _ rhs: AmbientFact) -> Bool {
        // THE PLACE'S ORDER. Built-ins keep their exact positions, so the
        // golden prompt diff is byte-identical; registrations sort after every
        // one of them, in roster order, which is what stops importing a package
        // from reordering the worlds the diff compares.
        if lhs.place.order != rhs.place.order { return lhs.place.order < rhs.place.order }
        if lhs.slot.order != rhs.slot.order { return lhs.slot.order < rhs.slot.order }
        return lhs.key.id < rhs.key.id
    }

    private static func prune(_ facts: inout [AmbientKey: AmbientFact], at now: Date) {
        for (key, fact) in Array(facts) where fact.isExpired(at: now) { facts[key] = nil }
    }

    /// "Nothing accumulates unboundedly", enforced: the newest
    /// `namedReadCap` reads per LANE survive, the rest drop oldest-first.
    ///
    /// Keyed on `isRead`, NOT on `!isPerceived`: a standing digest is also
    /// non-perceived, and counting it here would let a fourth calendar read
    /// evict the one-line summary of the user's day.
    ///
    /// A LANE, NOT A WORLD, since `.applications` is one world shared by every
    /// registered application. Bucketing by world would make Sketch's four
    /// reads and Keynote's four reads compete for one budget of four, so
    /// reading a fourth thing in Sketch would silently evict what the user
    /// just read in Keynote — a fact vanishing for a reason that has nothing
    /// to do with the conversation it belonged to. Nil application is its own
    /// lane, which is every built-in world's, unchanged.
    private static func capNamedReads(
        _ facts: inout [AmbientKey: AmbientFact],
        world: AmbientWorld,
        application: String?
    ) {
        let reads = facts.values
            .filter { $0.world == world && $0.application == application && $0.slot.isRead }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard reads.count > namedReadCap else { return }
        for fact in reads.dropFirst(namedReadCap) { facts[fact.key] = nil }
    }

    /// Publishes held facts onward to whatever is observing. Nothing is,
    /// today — see `AmbientObserving`.
    private func emit(_ facts: [AmbientFact]) {
        guard let observer = observerBox.withLock({ $0 }) else { return }
        Task { for fact in facts { await observer.observed(fact) } }
    }
}
