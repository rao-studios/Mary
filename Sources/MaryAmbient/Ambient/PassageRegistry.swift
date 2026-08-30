//
//  PassageRegistry.swift
//  MaryBrain
//
//  WHAT: Who holds the handles. [S1] in, a Passage out.
//  IN:   Passage.identity
//  OUT:  model / Skills. Twin: ContainerRegistry (HandleMap, different retention).
//  PIN:  Minting is idempotent by identity. One minting rule in this tree.
//

import Foundation
import os

/// Process-wide and lock-boxed, following `AmbientContextStore`: minted from
/// the dispatcher, resolved from the Skill execution lane, rendered by the debugger pane,
/// all on different actors. That is a real data race unless it is a lock box.
public final class PassageRegistry: @unchecked Sendable {

    public static let shared = PassageRegistry(elementIndexStore: .shared)

    /// The prefix letter, in one place so a rename is one line. The taken letters, checked: `E`
    /// events, `D` Scrivener documents, `T` message threads, `M` mail, `P` people, `N` notes,
    /// `F` files, `R` reminders. `S` is free, and a passage IS a span of text.
    public static let handlePrefix = "S"

    /// EXACTLY the ambient store's read window (1200 s). Read from `AmbientFact.defaultRetention`
    /// so the prompt can never show a handle this registry has already dropped.
    public static var retention: TimeInterval {
        // `.namedRead`'s associated value is the phrase that found the read.
        AmbientFact.defaultRetention(slot: .read(""))
    }

    /// The backstop, derived rather than picked: `AmbientContextStore` caps named reads at 4
    /// PER WORLD , and only passage-bearing worlds can hold them . A backstop, not the policy.
    /// `retention` is the policy.
    public static var cap: Int {
        AmbientContextStore.namedReadCap * passageBearingPlaceCount * 2
    }

    /// The worlds that can hold a passage, plus every registered application that EARNED eyes.
    /// Derived rather than pinned, for exactly the reason the comment above gives: the
    /// derivation is what moved this from 24 to 32 when TextEdit arrived, instead of somebody.
    public static var passageBearingPlaceCount: Int {
        // EVERY PASSAGE-BEARING PLACE IS A REGISTRATION.
        max(1, AmbientApplicationIndexProvider.current.all.filter(\.hasEyes).count)
    }

    /// One superseded handle's forwarding note.
    private struct Forward: Sendable {
        var replacedBy: String
        var at: Date
    }

    private struct State: Sendable {
        var handles = HandleMap(prefix: PassageRegistry.handlePrefix)
        /// NORMALIZED handle → passage. KEYED ON `normalize(_:)`, not on the minted spelling.
        /// `HandleMap` mints "S1".
        var passages: [String: Passage] = [:]
        var forwards: [String: Forward] = [:]
    }

    private let box = OSAllocatedUnfairLock<State>(initialState: State())

    /// Where minted passages publish as embeddable records — the same gate
    /// the design ledger ranks through. Private per instance for tests; the
    /// singleton shares the ambient-wide store.
    private let elementIndexStore: AmbientElementIndexStore

    public init(elementIndexStore: AmbientElementIndexStore? = nil) {
        self.elementIndexStore = elementIndexStore ?? AmbientElementIndexStore()
    }

    /// The gate's partition for one document's passages. `key` keeps the document
    /// discriminator.
    public static func scope(place: AmbientPlace, documentKey: String) -> AmbientElementScope {
        AmbientElementScope(place: place, key: "\(place.token)|\(documentKey)")
    }

    /// The built-in spelling, byte-identical for a native place.
    public static func scope(world: AmbientWorld, documentKey: String) -> AmbientElementScope {
        scope(place: .lane(world), documentKey: documentKey)
    }

    /// Republish one document's live passages. Outside the state lock, like
    /// every publisher — the store vectorizes.
    private func publishElements(place: AmbientPlace, documentKey: String, at now: Date) {
        let scope = Self.scope(place: place, documentKey: documentKey)
        let passages = live(at: now)
            .filter { $0.place == place && $0.documentKey == documentKey }
        elementIndexStore.noteElements(
            PassageRule.records(for: passages, scope: scope), scope: scope)
    }

    /// Passages of one document, ranked by relevancy to a spoken phrase —
    /// the fuzzy-title/substring matching every caller used to hand-roll,
    /// answered by the reference gate instead.
    public func rankedPassages(
        matching phrase: String, place: AmbientPlace, documentKey: String
    ) -> [RankedAmbientElement] {
        AmbientReferenceGate.rank(
            phrase: phrase,
            scope: Self.scope(place: place, documentKey: documentKey),
            requires: [.prose],
            store: elementIndexStore)
    }

    /// The built-in spelling.
    public func rankedPassages(
        matching phrase: String, world: AmbientWorld, documentKey: String
    ) -> [RankedAmbientElement] {
        rankedPassages(matching: phrase, place: .lane(world), documentKey: documentKey)
    }

    // MARK: - Minting

    /// Mint (or re-use) the handle for a located passage.
    @discardableResult
    public func mint(
        place: AmbientPlace,
        documentKey: String,
        documentTitle: String,
        text: String,
        bodyHash: String,
        bodyLength: Int,
        range: Range<Int>,
        unitKind: PassageUnitKind,
        locatorNote: String = "",
        provenance: AmbientProvenance,
        at now: Date = Date()
    ) -> Passage? {
        guard Passage.canHold(place) else { return nil }
        let identity = Passage.identity(place: place, documentKey: documentKey, text: text)
        let minted = box.withLock { state -> Passage? in
            Self.prune(&state, at: now)
            let handle = state.handles.handle(for: identity)
            guard var passage = Passage(
                handle: handle,
                place: place,
                documentKey: documentKey,
                documentTitle: documentTitle,
                text: text,
                bodyHash: bodyHash,
                bodyLength: bodyLength,
                range: range,
                unitKind: unitKind,
                locatorNote: locatorNote,
                mintedAt: now,
                provenance: provenance
            ) else { return nil }
            // A RE-READ REFRESHES THE HINT AND THE CLOCK, keeping the handle.
            let key = Self.normalize(handle)
            if let existing = state.passages[key] {
                passage.locatorNote = locatorNote.isEmpty ? existing.locatorNote : locatorNote
            }
            state.passages[key] = passage
            Self.capOldest(&state)
            return passage
        }
        if minted != nil {
            publishElements(place: place, documentKey: documentKey, at: now)
        }
        return minted
    }

    /// The built-in spelling, so every native read site mints exactly as it did.
    @discardableResult
    public func mint(
        world: AmbientWorld,
        documentKey: String,
        documentTitle: String,
        text: String,
        bodyHash: String,
        bodyLength: Int,
        range: Range<Int>,
        unitKind: PassageUnitKind,
        locatorNote: String = "",
        provenance: AmbientProvenance,
        at now: Date = Date()
    ) -> Passage? {
        mint(
            place: .lane(world),
            documentKey: documentKey,
            documentTitle: documentTitle,
            text: text,
            bodyHash: bodyHash,
            bodyLength: bodyLength,
            range: range,
            unitKind: unitKind,
            locatorNote: locatorNote,
            provenance: provenance,
            at: now)
    }

    // MARK: - Resolving

    /// What does this handle mean NOW? Tolerant about spelling the same way
    /// `HandleMap.identifier(forHandle:)` is — `[S1]`, `s1` and ` S1 ` are all
    /// the same handle, because that is how a model writes it back.
    public func resolve(_ raw: String, at now: Date = Date()) -> PassageResolution {
        let handle = Self.normalize(raw)
        guard !handle.isEmpty else { return .unknown }
        return box.withLock { state -> PassageResolution in
            Self.prune(&state, at: now)
            if let passage = state.passages[handle] { return .live(passage) }
            if let forward = state.forwards[handle] {
                return .superseded(replacedBy: forward.replacedBy)
            }
            return .unknown
        }
    }

    /// Forwarding address after a write remints. Without it, later "[S1]" is unknown.
    public func supersede(_ old: String, with passage: Passage, at now: Date = Date()) {
        let oldKey = Self.normalize(old)
        let newKey = Self.normalize(passage.handle)
        guard !oldKey.isEmpty, oldKey != newKey else { return }
        box.withLock { state in
            Self.prune(&state, at: now)
            state.passages[oldKey] = nil
            state.forwards[oldKey] = Forward(replacedBy: passage.handle, at: now)
            state.passages[newKey] = passage
            Self.capOldest(&state)
        }
        publishElements(place: passage.place, documentKey: passage.documentKey, at: now)
    }

    /// Every live passage, newest first — the debugger pane's query.
    public func live(at now: Date = Date()) -> [Passage] {
        box.withLock { state -> [Passage] in
            Self.prune(&state, at: now)
            return state.passages.values.sorted { lhs, rhs in
                if lhs.mintedAt != rhs.mintedAt { return lhs.mintedAt > rhs.mintedAt }
                return lhs.handle < rhs.handle
            }
        }
    }

    /// Test isolation — the process-wide box must never leak between suites
    /// (`AmbientContextStore.clear`'s precedent, and the ledger's before it).
    public func clear() {
        box.withLock { $0 = State() }
    }

    // MARK: - Internals

    /// Mirrors `HandleMap.identifier(forHandle:)`'s tolerance, minus its
    /// raw-identifier passthrough (see `State.passages`).
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " []")).lowercased()
    }

    /// The SAME expiry predicate `AmbientFact.isExpired` uses — strictly greater, not `>=`. A
    /// one-tick disagreement at the boundary is exactly the window in which the prompt would
    /// carry a handle this registry had already forgotten.
    private static func prune(_ state: inout State, at now: Date) {
        let window = retention
        for (key, passage) in state.passages
        where now.timeIntervalSince(passage.mintedAt) > window {
            state.passages[key] = nil
        }
        for (key, forward) in state.forwards
        where now.timeIntervalSince(forward.at) > window {
            state.forwards[key] = nil
        }
    }

    /// Oldest first, like `AmbientContextStore.capNamedReads`. Forwards are
    /// capped alongside so a long turn of edits cannot grow them unbounded;
    /// they are one string each, so the same number is generous for them.
    private static func capOldest(_ state: inout State) {
        let limit = cap
        if state.passages.count > limit {
            let doomed = state.passages.values
                .sorted { $0.mintedAt > $1.mintedAt }
                .dropFirst(limit)
            for passage in doomed { state.passages[normalize(passage.handle)] = nil }
        }
        if state.forwards.count > limit {
            let doomed = state.forwards
                .sorted { $0.value.at > $1.value.at }
                .dropFirst(limit)
            for entry in doomed { state.forwards[entry.key] = nil }
        }
    }
}
