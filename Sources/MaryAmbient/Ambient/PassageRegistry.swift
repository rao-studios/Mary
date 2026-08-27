//
//  PassageRegistry.swift
//  MaryBrain
//
//  WHO HOLDS THE HANDLES. `[S1]` in, a `Passage` out — the seam that lets the
//  model name a piece of a document without ever seeing a character offset.
//
//  THE SAME SEAM AS EVERYTHING ELSE, deliberately. Notes mint `[N#]` over
//  x-coredata URLs, Mail `[M#]` over message ids, Files `[F#]` over paths,
//  Calendar `[E#]` over EventKit identifiers — all of them `HandleMap`, all of
//  them for the same reason: the model must not round-trip a fragile long
//  identifier through conversation. A passage is that problem in its purest
//  form, because its "identifier" is a paragraph of prose. So this wraps
//  `HandleMap`; it does not invent a second handle mechanism. There is one
//  minting rule in this tree and this is it.
//
//  MINTING IS IDEMPOTENT BY IDENTITY (`Passage.identity` —
//  `world|documentKey|hash(text)`). Read the same paragraph twice and the
//  conversation keeps calling it `[S1]`. `HandleMap.handle(for:)` already
//  gives exactly this — it returns the existing handle for a known identifier
//  — so the idempotence is inherited, not re-implemented.
//
//  PRUNED ON THE AMBIENT STORE'S OWN READ WINDOW, and that equality is
//  load-bearing rather than tidy: the prompt shows handles because a
//  `namedRead` fact is rendered beside them. If this store forgot first, the
//  prompt would offer `[S1]` and the Skill would answer "I don't know what that
//  is" — a handle the model can see and cannot use is worse than no handle.
//  So `retention` IS `AmbientFact.defaultRetention(slot: .namedRead)`, read
//  from there, with the same strictly-greater expiry predicate.
//
//  HEADLESS-SAFE: Foundation + os. (`ContentUndoStore.hash` is reused for
//  identity — same algorithm as every other hash in the passage path, so a
//  body hashed by the writer and a body hashed here can never disagree.)
//

import Foundation
import os

/// Process-wide and lock-boxed, following `AmbientContextStore`: minted from
/// the dispatcher, resolved from the Skill execution lane, rendered by the debugger pane,
/// all on different actors. That is a real data race unless it is a lock box.
public final class PassageRegistry: @unchecked Sendable {

    public static let shared = PassageRegistry(elementIndexStore: .shared)

    /// The prefix letter, in one place so a rename is one line.
    ///
    /// `S` FOR SPAN, AND IT IS NOT `P`. The obvious letter was taken: `P` is
    /// Contacts' PEOPLE prefix (`ContactsStore`, `HandleMap(prefix: "P")`).
    /// The two maps are separate objects, so nothing would ever resolve across
    /// them — the failure is not a wrong lookup, it is a wrong THOUGHT. A
    /// transcript holding a person and a passage would have shown the model
    /// two `[P1]`s meaning different things — and the whole point of a handle
    /// is that
    /// the model can carry it between turns without inspecting it. A handle
    /// that means two things is not a handle.
    ///
    /// The taken letters, checked: `E` events, `D` Scrivener documents,
    /// `T` message threads, `M` mail, `P` people, `N` notes, `F` files,
    /// `R` reminders. `S` is free, and a passage IS a span of text.
    public static let handlePrefix = "S"

    /// EXACTLY the ambient store's read window (1200 s). Read from there
    /// rather than repeated, so the prompt can never show a handle this
    /// registry has already dropped. See the header.
    public static var retention: TimeInterval {
        // `.namedRead`'s associated value is the phrase that found the read.
        // The window does not depend on it — `defaultRetention` matches the
        // case and ignores the phrase — so an empty one is passed rather than
        // a plausible-looking fake, which nothing should mistake for a slot
        // this registry actually holds.
        AmbientFact.defaultRetention(slot: .read(""))
    }

    /// The backstop, derived rather than picked: `AmbientContextStore` caps
    /// named reads at 4 PER WORLD (`namedReadCap`), and only passage-bearing
    /// worlds can hold them (`AmbientWorld.passageBearing`, currently 4).
    /// So at most 4 × 4 = 16 reads can be live in the store at once. Doubled,
    /// because an edit SUPERSEDES rather than replaces: the old handle stays
    /// resolvable so Mary can say "that was [S1] — it's [S4] now", which
    /// means one read can legitimately account for two entries here.
    /// 4 × 4 × 2 = 32 (it was 24 while there were three watched worlds; TextEdit
    /// is the fourth, and the derivation is what moved it rather than a new
    /// literal — which is the property this expression exists for).
    ///
    /// A backstop, not the policy. `retention` is the policy; this only bounds
    /// a pathological turn that mints faster than 20 minutes can forget.
    public static var cap: Int {
        AmbientContextStore.namedReadCap * passageBearingPlaceCount * 2
    }

    /// The worlds that can hold a passage, plus every registered application
    /// that EARNED eyes.
    ///
    /// Derived rather than pinned, for exactly the reason the comment above
    /// gives: the derivation is what moved this from 24 to 32 when TextEdit
    /// arrived, instead of somebody remembering to edit a literal. A registered
    /// application that can hold passages needs its own read budget for the
    /// same reason a fourth watched world did — otherwise its reads evict the
    /// ones the user asked for in a different application.
    public static var passageBearingPlaceCount: Int {
        // EVERY PASSAGE-BEARING PLACE IS A REGISTRATION. Bonnie added a
        // compiled `passageBearing` count to this — the worlds with both an
        // observer and prose backing — and its own comment warned that a
        // recognized-but-unobserved world must not widen the backstop.
        // `hasEyes` is that same two-halves test, asked of the roster.
        max(1, AmbientApplicationIndexProvider.current.all.filter(\.hasEyes).count)
    }

    /// One superseded handle's forwarding note.
    private struct Forward: Sendable {
        var replacedBy: String
        var at: Date
    }

    private struct State: Sendable {
        var handles = HandleMap(prefix: PassageRegistry.handlePrefix)
        /// NORMALIZED handle → passage. NOT `HandleMap.identifier(forHandle:)`:
        /// that method passes any string longer than 8 characters straight
        /// back as a raw identifier, which is right for a Notes URL the model
        /// echoed and wrong here — it would turn a hallucinated sentence into
        /// a "resolved" passage identity. Resolution here is a lookup in a map
        /// this registry filled, or it is `.unknown`.
        ///
        /// KEYED ON `normalize(_:)`, not on the minted spelling. `HandleMap`
        /// mints "S1"; a model writes back "[s1]" as often as not, and a
        /// dictionary that is case-sensitive on one side of that and tolerant
        /// on the other resolves nothing at all.
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

    /// The gate's partition for one document's passages. `key` keeps the
    /// document discriminator — a place names the lane, not the document
    /// inside it.
    ///
    /// `place.token` is the discriminator BOTH halves need: two taught
    /// applications ride the same `.applications` host lane, so a key built from
    /// the host world's `rawValue` would file both manuscripts under one
    /// partition and let a phrase in one rank a passage from the other.
    public static func scope(place: AmbientRealm, documentKey: String) -> AmbientElementScope {
        AmbientElementScope(realm: place, key: "\(place.token)|\(documentKey)")
    }

    /// The built-in spelling, byte-identical for a native realm.
    public static func scope(world: AmbientWorld, documentKey: String) -> AmbientElementScope {
        scope(place: .native(world), documentKey: documentKey)
    }

    /// Republish one document's live passages. Outside the state lock, like
    /// every publisher — the store vectorizes.
    private func publishElements(place: AmbientRealm, documentKey: String, at now: Date) {
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
        matching phrase: String, place: AmbientRealm, documentKey: String
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
        rankedPassages(matching: phrase, place: .native(world), documentKey: documentKey)
    }

    // MARK: - Minting

    /// Mint (or re-use) the handle for a located passage.
    ///
    /// Returns nil for a place that cannot hold passages — see
    /// `Passage.init?`. The optional is the honest shape: a caller with a
    /// `.calendar` world has not made a small mistake, it has made a category
    /// error, and handing it a handle no writer could satisfy would only move
    /// the failure to the write site.
    @discardableResult
    public func mint(
        place: AmbientRealm,
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
            // The same words at a new offset in a longer body are the same
            // passage — that is what identifying by text MEANS — but the stale
            // range and the stale body hash are worse than useless, because
            // the resolver would take the hash mismatch as drift it has to
            // search for when the caller has just handed it the truth.
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
            place: .native(world),
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

    /// The edited passage's forwarding address. Called after a write lands and
    /// the new text has been re-minted.
    ///
    /// THE BLANK FAILURE THIS REPLACES: without it, "make it shorter still"
    /// two turns after an edit resolves `[S1]` to nothing, and the only honest
    /// thing left to say is "I don't know what that is" — about a passage
    /// Mary herself changed thirty seconds ago. With it she says "that was
    /// [S1] — I replaced it, it's [S4] now" and the turn continues.
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

    /// The SAME expiry predicate `AmbientFact.isExpired` uses — strictly
    /// greater, not `>=`. A one-tick disagreement at the boundary is exactly
    /// the window in which the prompt would carry a handle this registry had
    /// already forgotten.
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
