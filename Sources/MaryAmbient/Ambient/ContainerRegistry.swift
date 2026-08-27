//
//  ContainerRegistry.swift
//  MaryBrain
//
//  HANDLES FOR CONTAINERS, and the memory of what was last shown.
//
//  `PassageRegistry`'s structural twin — same lock box, same `normalize`, same
//  refusal of `HandleMap`'s raw passthrough — and DELIBERATELY NOT the same
//  type. See `ContainerRow`'s header for the four properties that differ; the
//  short version is that a span dies by supersession and a container dies by
//  closure, and one retention rule cannot serve both.
//
//  ═══════════════════════════════════════════════════════════════════════
//  IDENTITY, NOT POSITION. This is the bug it exists to fix.
//
//  TextEdit's `[W#]` was minted as `handles["W\(offset + 1)"] = window.id` —
//  the row's place in a z-ordered roster — and the whole map was replaced on
//  every listing. So raising a window and listing again made `[W2]` name a
//  DIFFERENT note, silently, while the conversation went on calling it `[W2]`.
//
//  Minting through `HandleMap` keyed on the world's own `documentKey` makes a
//  handle mean one container for the whole conversation. `HandleMap.handle`
//  is idempotent by identifier, so this is free.
//
//  AND EXPIRY IS STILL HONEST, without a clock: a container handle resolves to
//  a KEY, and the key is validated against the world's LIVE enumeration at the
//  point of use (`TextEditPlugin.windowID(forDocumentKey:)` already does
//  exactly this and answers nil for a window that has closed). Identity gives
//  stability; live validation gives expiry. Neither needs a retention window,
//  which is why this registry has none and `PassageRegistry` must.
//  ═══════════════════════════════════════════════════════════════════════
//
//  IT ADOPTS RATHER THAN RE-MINTS. `[N#]`, `[M#]`, `[D#]`, `[T#]`, `[F#]` are
//  already minted by their own plugins over their own identifiers. Moving them
//  would be a removal-shaped change to five working worlds for no gain, so a
//  world may hand over a handle it already minted and this registry simply
//  records it. Only `[W#]` migrates, because it is the one that was wrong.
//
//  KEYED BY REALM, so a REGISTERED APPLICATION has container identity of its
//  own. The ledger keys on `AmbientRealm.token` — byte-identical to the bare
//  raw value for every native world, `other_apps:<id>` for a registration —
//  which is what lets two registered applications share the `.applications` host
//  lane without their containers colliding, and what a world-keyed ledger
//  could never grant them. The world-labeled API below is the native
//  projection, not a leftover: a native realm IS its world, so a built-in
//  plugin keeps speaking world and mints exactly the bytes it always did.
//

import Foundation
import os

/// WHAT WAS LAST SHOWN TO THE MODEL, in the order it was shown.
///
/// The thing an ordinal counts. "The second one" means nothing without a list
/// the user actually saw, so this is what makes cardinals resolvable — and
/// what makes them ABSTAIN when no listing has happened.
public struct ContainerListing: Sendable, Equatable {
    public var realm: AmbientRealm
    /// The keys, in the order the listing binding rendered them.
    public var keys: [String]
    public var at: Date

    /// The closed world half — for a registered application, the host lane it
    /// rides. Kept because most readers only ask "which built-in".
    public var world: AmbientWorld { realm.world }

    public init(realm: AmbientRealm, keys: [String], at: Date) {
        self.realm = realm
        self.keys = keys
        self.at = at
    }

    /// The native spelling, unchanged for every built-in caller.
    public init(world: AmbientWorld, keys: [String], at: Date) {
        self.init(realm: .native(world), keys: keys, at: at)
    }
}

/// WHY A CONTAINER IS SALIENT — and the classes are ordered, not scored.
///
/// Lexicographic over classes, most-recent-first WITHIN a class. Mixing "the
/// user touched it" with "Mary mentioned it" on one numeric scale is how a
/// coin toss acquires a score; `PassageWidening`'s tie-break refuses that for
/// the same reason and this follows it.
///
/// Ties inside a class that a timestamp cannot break ABSTAIN, exactly as
/// `uniqueTitleMatch` abstains on two equally-long name matches.
public enum ContainerEvidence: Int, Sendable, Equatable, CaseIterable, Comparable {
    /// THE USER TOLD US DIRECTLY — "no, the other one".
    ///
    /// Above everything, and it is the only class that is not an inference. The
    /// other five are Mary behavior: what she changed, read, said, listed,
    /// and where the user was. This one is the user correcting her
    /// out loud, which is the highest-grade evidence a conversation produces and
    /// the whole reason the doctrine's third clause exists.
    case corrected = -1
    /// Mary CHANGED it this conversation. The strongest claim there is: the
    /// user asked for an edit and it landed here.
    case actedOn = 0
    /// Mary successfully READ this exact container through a structurally
    /// identified passage. This is conversation evidence even when the read
    /// result travels through a Skill lane rather than the speaking lane. It
    /// outranks a prose mention and frontmost state because a requested read
    /// targets one machine-verified container identity.
    case read = 1
    /// Mary SPOKE about it. `AmbientFact.spokenAt` already records this and
    /// nothing consumed it until now.
    case spokenAbout = 2
    /// The USER's own attention: they were in it. For a window world this is
    /// front-ness; never a body change, which is autosave rather than intent.
    ///
    /// ABOVE `.shown`, and the order was the other way round until a live check
    /// showed why it cannot be. A LISTING STAMPS EVERY CONTAINER AT ONCE, so
    /// `.shown` is the least discriminating signal there is by construction —
    /// eight notes listed together are eight notes with identical evidence. The
    /// user having been IN one of them is a fact about exactly one. "The one I
    /// was just in" has to beat "one of the eight I printed for you".
    case touched = 3
    /// A roster row was rendered for it — the model has been shown it exists.
    /// The weakest claim, because a listing confers it on everything.
    case shown = 4

    public static func < (lhs: ContainerEvidence, rhs: ContainerEvidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public final class ContainerRegistry: @unchecked Sendable {

    public static let shared = ContainerRegistry()

    /// HOW LONG A REFERENTIAL CLAIM LASTS.
    ///
    /// Conversation memory — acted on, read, spoken about, shown — expires on
    /// the ambient store's own window, DERIVED rather than duplicated, so a
    /// salience claim can never outlive the prompt that could explain it.
    ///
    /// `.touched` deliberately does NOT expire here: it is world state, and it
    /// dies when the container closes and drops out of the live enumeration.
    /// That split is the whole answer to "how does salience decay" —
    /// conversation memory expires, world state is re-read.
    public static var evidenceRetention: TimeInterval {
        AmbientFact.defaultRetention(slot: .read(""))
    }

    private struct State: Sendable {
        /// One `HandleMap` per prefix — `W` for TextEdit, `D` for Scrivener.
        /// Per-prefix rather than one shared map so two realms cannot mint the
        /// same string for different things.
        var handles: [String: HandleMap] = [:]
        /// NORMALIZED handle → `(realm, key)`. Not `HandleMap.identifier(forHandle:)`:
        /// that passes any string longer than 8 characters straight back as a
        /// raw identifier, which is right for a Notes URL a model echoed and
        /// wrong here — it would turn a hallucinated sentence into a
        /// "resolved" container. Resolution here is a lookup in a map this
        /// registry filled, or it is nil.
        var byHandle: [String: (realm: AmbientRealm, key: String)] = [:]
        /// The most recent listing per realm — one per registered application,
        /// not one shared slot for the whole `.applications` host lane.
        var listings: [AmbientRealm: ContainerListing] = [:]
        /// `realm.token|key` → the newest stamp per evidence class.
        var evidence: [String: [ContainerEvidence: Date]] = [:]
    }

    private let box = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    // MARK: - Handles

    /// Mint (or re-use) the handle for one container. Idempotent by
    /// `(realm, key)`, so a container keeps its handle for the conversation
    /// however many times it is listed.
    @discardableResult
    public func handle(realm: AmbientRealm, prefix: String, key: String) -> String {
        box.withLock { state in
            var map = state.handles[prefix] ?? HandleMap(prefix: prefix)
            // Scope the identifier by realm token so two realms sharing a
            // prefix (none today, but the table is open) cannot collide —
            // including two registered applications on one host lane.
            let handle = map.handle(for: "\(realm.token)|\(key)")
            state.handles[prefix] = map
            state.byHandle[Self.normalize(handle)] = (realm, key)
            // MINTING IS *NOT* BEING SHOWN, and this comment used to say the
            // opposite. Caught live: `ReferenceFocus.resolve` mints a handle for
            // every candidate on every turn, so stamping `.shown` here gave all
            // eight open notes evidence with near-identical timestamps — and
            // "the other one" then resolved to whichever was minted last, which
            // is roster order. A coin toss wearing a rank.
            //
            // Being SHOWN means the MODEL SAW IT, which is a listing — so
            // `noteListing` stamps it and nothing else does.
            return handle
        }
    }

    /// The native projection — a built-in world mints exactly the bytes it
    /// always did (`realm.token == rawValue` for every native case).
    @discardableResult
    public func handle(world: AmbientWorld, prefix: String, key: String) -> String {
        handle(realm: .native(world), prefix: prefix, key: key)
    }

    /// Record a handle a realm minted ITSELF, so `[D3]` from Scrivener's own
    /// `HandleMap` resolves here too. Adoption, not re-minting — see the file
    /// header.
    public func adopt(handle: String, realm: AmbientRealm, key: String) {
        box.withLock { $0.byHandle[Self.normalize(handle)] = (realm, key) }
    }

    /// The native projection of `adopt(handle:realm:key:)`.
    public func adopt(handle: String, world: AmbientWorld, key: String) {
        adopt(handle: handle, realm: .native(world), key: key)
    }

    /// The container a handle names, or nil. Tolerant of `[W1]`, `w1`, ` W1 `
    /// — a model writes back whichever it likes.
    public func resolveRealm(_ raw: String) -> (realm: AmbientRealm, key: String)? {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        return box.withLock { $0.byHandle[normalized] }
    }

    /// The world projection of `resolveRealm(_:)` — a registered application's
    /// container answers with its host lane here, which is what a caller
    /// asking "is this one of TextEdit's?" needs and nothing more.
    public func resolve(_ raw: String) -> (world: AmbientWorld, key: String)? {
        resolveRealm(raw).map { ($0.realm.world, $0.key) }
    }

    // MARK: - Salience

    /// Record that something referential happened to a container.
    public func noteEvidence(
        realm: AmbientRealm, key: String, _ kind: ContainerEvidence,
        at now: Date = Date()
    ) {
        let id = Self.evidenceKey(realm: realm, key: key)
        box.withLock { $0.evidence[id, default: [:]][kind] = now }
    }

    /// The native projection of `noteEvidence(realm:key:_:at:)`.
    public func noteEvidence(
        world: AmbientWorld, key: String, _ kind: ContainerEvidence,
        at now: Date = Date()
    ) {
        noteEvidence(realm: .native(world), key: key, kind, at: now)
    }

    /// The strongest live claim on a container, and when it was made. Nil when
    /// nothing referential has happened to it — which is a real answer, and the
    /// one that keeps a never-mentioned container out of every anaphoric pick.
    public func evidence(
        realm: AmbientRealm, key: String, at now: Date = Date()
    ) -> (kind: ContainerEvidence, at: Date)? {
        let id = Self.evidenceKey(realm: realm, key: key)
        let stamps = box.withLock { $0.evidence[id] ?? [:] }
        let live = stamps.filter { kind, at in
            // `.touched` is world state and never expires here; the rest are
            // conversation memory — see `evidenceRetention`.
            kind == .touched || now.timeIntervalSince(at) <= Self.evidenceRetention
        }
        guard let best = live.keys.min() else { return nil }
        return (best, live[best] ?? .distantPast)
    }

    /// The native projection of `evidence(realm:key:at:)`.
    public func evidence(
        world: AmbientWorld, key: String, at now: Date = Date()
    ) -> (kind: ContainerEvidence, at: Date)? {
        evidence(realm: .native(world), key: key, at: now)
    }

    /// Whether any selected conversation event happened after a boundary.
    /// This deliberately examines the raw per-class timestamps rather than
    /// `evidence(...)`, whose job is different: it returns the strongest class
    /// for salience. An older `.actedOn` must not hide a newer `.read` when the
    /// question is whether a roster listing is still the newest event.
    public func hasEvidence(
        realm: AmbientRealm,
        key: String,
        kinds: Set<ContainerEvidence>,
        newerThan boundary: Date,
        at now: Date = Date()
    ) -> Bool {
        let id = Self.evidenceKey(realm: realm, key: key)
        let stamps = box.withLock { $0.evidence[id] ?? [:] }
        return stamps.contains { kind, stamp in
            guard kinds.contains(kind), stamp > boundary else { return false }
            return kind == .touched
                || now.timeIntervalSince(stamp) <= Self.evidenceRetention
        }
    }

    /// The native projection of `hasEvidence(realm:key:kinds:newerThan:at:)`.
    public func hasEvidence(
        world: AmbientWorld,
        key: String,
        kinds: Set<ContainerEvidence>,
        newerThan boundary: Date,
        at now: Date = Date()
    ) -> Bool {
        hasEvidence(
            realm: .native(world), key: key, kinds: kinds,
            newerThan: boundary, at: now)
    }

    /// SALIENCE AS A RANK — 0 is most salient, nil is no evidence at all.
    ///
    /// Class first, recency second, which is the lexicographic order
    /// `ContainerEvidence` documents. Returned as a plain `Int` because that is
    /// all `ReferenceResolver` needs: it compares, it never interprets.
    public func salienceRanks(
        realm: AmbientRealm, keys: [String], at now: Date = Date()
    ) -> [String: Int] {
        let scored: [(key: String, kind: ContainerEvidence, at: Date)] = keys.compactMap { key in
            guard let found = evidence(realm: realm, key: key, at: now) else { return nil }
            return (key, found.kind, found.at)
        }
        let ordered = scored.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind : $0.at > $1.at
        }
        // AN UNBREAKABLE TIE IS NOT A RANK. Two containers with the same class
        // AND the same instant are indistinguishable, and handing one of them
        // rank 0 is a coin toss wearing a number — the thing this whole ladder
        // refuses. Both are dropped, so the anaphora rung sees no evidence and
        // abstains rather than guessing which note to rewrite.
        //
        // CAUGHT LIVE: `noteListing` stamps every key at one instant, so a
        // roster of eight notes produced eight tied `.shown` entries and "the
        // other one" resolved to whichever the sort happened to put first.
        let tied = Set(
            ordered.filter { row in
                ordered.contains { $0.key != row.key && $0.kind == row.kind && $0.at == row.at }
            }.map(\.key))
        return Dictionary(
            uniqueKeysWithValues: ordered
                .filter { !tied.contains($0.key) }
                .enumerated().map { ($1.key, $0) })
    }

    /// The native projection of `salienceRanks(realm:keys:at:)`.
    public func salienceRanks(
        world: AmbientWorld, keys: [String], at now: Date = Date()
    ) -> [String: Int] {
        salienceRanks(realm: .native(world), keys: keys, at: now)
    }

    /// A CORRECTION, RECORDED BOTH WAYS.
    ///
    /// Promoting the intended container is half the job. The other half is
    /// DEMOTING the rejected one — a container the user has explicitly rejected
    /// this conversation must not win the next anaphoric pick just because it
    /// was the most recent thing Mary touched. Without the demotion, "no, the
    /// other one" followed by "add this too" would land straight back where the
    /// correction rejected.
    ///
    /// Demotion is a REMOVAL of the rejected container's evidence, not a
    /// negative score: `salienceRanks` has no rank for a container with no
    /// evidence, which is exactly "stop preferring this" without inventing an
    /// anti-preference the ordering has no room for.
    public func noteCorrection(
        realm: AmbientRealm, rejected: String?, intended: String,
        at now: Date = Date()
    ) {
        let intendedKey = Self.evidenceKey(realm: realm, key: intended)
        box.withLock { state in
            if let rejected {
                state.evidence.removeValue(
                    forKey: Self.evidenceKey(realm: realm, key: rejected))
            }
            state.evidence[intendedKey, default: [:]][.corrected] = now
        }
    }

    /// The native projection of `noteCorrection(realm:rejected:intended:at:)`.
    public func noteCorrection(
        world: AmbientWorld, rejected: String?, intended: String,
        at now: Date = Date()
    ) {
        noteCorrection(realm: .native(world), rejected: rejected, intended: intended, at: now)
    }

    /// `textedit|/tmp/todo.txt` / `other_apps:sketch|canvas-1`. The realm
    /// token IS the raw value for every native world, so built-in evidence
    /// keys are byte-identical to what the world-keyed ledger stored.
    public static func evidenceKey(realm: AmbientRealm, key: String) -> String {
        "\(realm.token)|\(key)"
    }

    /// The native projection of `evidenceKey(realm:key:)`.
    public static func evidenceKey(world: AmbientWorld, key: String) -> String {
        evidenceKey(realm: .native(world), key: key)
    }

    // MARK: - Listings

    /// Remember the order a listing binding just showed the model.
    public func noteListing(realm: AmbientRealm, keys: [String], at now: Date = Date()) {
        box.withLock { state in
            state.listings[realm] = ContainerListing(realm: realm, keys: keys, at: now)
            // A LISTING IS WHAT "SHOWN" MEANS — the model was handed these rows
            // and can refer to them. Recorded here rather than at handle-minting
            // time, because minting happens on every turn for every candidate
            // and would give the whole roster identical evidence.
            for key in keys {
                state.evidence[Self.evidenceKey(realm: realm, key: key), default: [:]][.shown] = now
            }
        }
    }

    /// The native projection of `noteListing(realm:keys:at:)`.
    public func noteListing(world: AmbientWorld, keys: [String], at now: Date = Date()) {
        noteListing(realm: .native(world), keys: keys, at: now)
    }

    /// The last listing for a realm, IF IT IS STILL TRUE.
    ///
    /// A listing goes stale the moment the realm's live enumeration disagrees
    /// with it — in membership OR in order. That is what stops "the last one"
    /// pointing at a row that has since moved: raise a window and the ordinal
    /// rung drops through to salience instead of naming the wrong note. The
    /// enumeration is already polled, so the check is free.
    public func listing(
        for realm: AmbientRealm, against live: [String]
    ) -> ContainerListing? {
        guard let listing = box.withLock({ $0.listings[realm] }) else { return nil }
        guard listing.keys == live else { return nil }
        return listing
    }

    /// The native projection of `listing(for:against:)`.
    public func listing(
        for world: AmbientWorld, against live: [String]
    ) -> ContainerListing? {
        listing(for: .native(world), against: live)
    }

    /// The raw remembered listing, staleness unchecked — for the debugger pane
    /// and for tests. Callers deciding anything must use `listing(for:against:)`.
    public func lastListing(for realm: AmbientRealm) -> ContainerListing? {
        box.withLock { $0.listings[realm] }
    }

    /// The native projection of `lastListing(for:)`.
    public func lastListing(for world: AmbientWorld) -> ContainerListing? {
        lastListing(for: .native(world))
    }

    /// Test isolation, and the shape `PassageRegistry.clear()` set.
    public func clear() {
        box.withLock { $0 = State() }
    }

    // MARK: - Normalization

    /// `[W1]` / `w1` / ` W1 ` all key the same entry. Deliberately WITHOUT
    /// `HandleMap`'s raw-identifier passthrough — see `State.byHandle`.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " []")).lowercased()
    }
}
