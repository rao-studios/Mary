//
//  ContainerRegistry.swift
//  MaryBrain
//
//  WHAT: Handles for containers, and memory of what was last shown.
//  OUT:  ReferenceFocus / prompt. Twin of PassageRegistry (same HandleMap, not the same type).
//  PIN:  Identity, not position. A span dies by supersession; a container dies by closure.
//

import Foundation
import os

/// WHAT WAS LAST SHOWN TO THE MODEL, in the order it was shown. The thing an ordinal
/// counts. "The second one" means nothing without a list the user actually saw, so this is
/// what makes cardinals resolvable.
public struct ContainerListing: Sendable, Equatable {
    public var place: AmbientPlace
    /// The keys, in the order the listing binding rendered them.
    public var keys: [String]
    public var at: Date

    /// The closed world half — for a registered application, the host lane it
    /// rides. Kept because most readers only ask "which built-in".
    public var attention: AmbientAttention { place.attention }

    public init(place: AmbientPlace, keys: [String], at: Date) {
        self.place = place
        self.keys = keys
        self.at = at
    }

    /// The native spelling, unchanged for every built-in caller.
    public init(attention: AmbientAttention, keys: [String], at: Date) {
        self.init(place: .lane(attention), keys: keys, at: at)
    }
}

/// WHY A CONTAINER IS SALIENT.
public enum ContainerEvidence: Int, Sendable, Equatable, CaseIterable, Comparable {
    /// THE USER TOLD US DIRECTLY — "no, the other one". Above everything, and it is the only
    /// class that is not an inference. The other five are Mary behavior: what she changed,
    /// read, said, listed, and where the user was.
    case corrected = -1
    /// Mary CHANGED it this conversation. The strongest claim there is: the
    /// user asked for an edit and it landed here.
    case actedOn = 0
    /// Mary successfully READ this exact container through a structurally identified passage.
    /// This is conversation evidence even when the read result travels through a Skill lane
    /// rather than the speaking lane.
    case read = 1
    /// Mary SPOKE about it. `AmbientFact.spokenAt` already records this and
    /// nothing consumed it until now.
    case spokenAbout = 2
    /// The USER's own attention: they were in it. For a window world this is front-ness; never
    /// a body change, which is autosave rather than intent. ABOVE `.shown`, and the order was
    /// the other way round until a live check showed why it cannot be.
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

    /// HOW LONG A REFERENTIAL CLAIM LASTS. Conversation memory — acted on, read, spoken about,
    /// shown — expires on the ambient store's own window, DERIVED rather than duplicated, so a
    /// salience claim can never outlive the prompt that could explain it.
    public static var evidenceRetention: TimeInterval {
        AmbientFact.defaultRetention(slot: .read(""))
    }

    private struct State: Sendable {
        /// One `HandleMap` per prefix — `W` for TextEdit, `D` for Scrivener.
        /// Per-prefix rather than one shared map so two places cannot mint the
        /// same string for different things.
        var handles: [String: HandleMap] = [:]
        /// NORMALIZED handle → `(place, key)`.
        var byHandle: [String: (place: AmbientPlace, key: String)] = [:]
        /// The most recent listing per place — one per registered application,
        /// not one shared slot for the whole `.applications` host lane.
        var listings: [AmbientPlace: ContainerListing] = [:]
        /// `place.token|key` → the newest stamp per evidence class.
        var evidence: [String: [ContainerEvidence: Date]] = [:]
    }

    private let box = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    // MARK: - Handles

    /// Mint (or re-use) the handle for one container. Idempotent by
    /// `(place, key)`, so a container keeps its handle for the conversation
    /// however many times it is listed.
    @discardableResult
    public func handle(place: AmbientPlace, prefix: String, key: String) -> String {
        box.withLock { state in
            var map = state.handles[prefix] ?? HandleMap(prefix: prefix)
            // Scope the identifier by place token so two places sharing a
            // prefix (none today, but the table is open) cannot collide —
            // including two registered applications on one host lane.
            let handle = map.handle(for: "\(place.token)|\(key)")
            state.handles[prefix] = map
            state.byHandle[Self.normalize(handle)] = (place, key)
            // MINTING IS *NOT* BEING SHOWN, and this comment used to say the opposite. Being SHOWN
            // means the MODEL SAW IT, which is a listing — so `noteListing` stamps it and nothing else
            // does.
            return handle
        }
    }

    /// The native projection — a built-in world mints exactly the bytes it
    /// always did (`place.token == rawValue` for every native case).
    @discardableResult
    public func handle(attention: AmbientAttention, prefix: String, key: String) -> String {
        handle(place: .lane(attention), prefix: prefix, key: key)
    }

    /// Record a handle a place minted ITSELF, so `[D3]` from Scrivener's own `HandleMap`
    /// resolves here too. Adoption, not re-minting.
    public func adopt(handle: String, place: AmbientPlace, key: String) {
        box.withLock { $0.byHandle[Self.normalize(handle)] = (place, key) }
    }

    /// The native projection of `adopt(handle:place:key:)`.
    public func adopt(handle: String, attention: AmbientAttention, key: String) {
        adopt(handle: handle, place: .lane(attention), key: key)
    }

    /// The container a handle names, or nil. Tolerant of `[W1]`, `w1`, ` W1 `
    /// — a model writes back whichever it likes.
    public func resolvePlace(_ raw: String) -> (place: AmbientPlace, key: String)? {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        return box.withLock { $0.byHandle[normalized] }
    }

    /// The world projection of `resolvePlace(_:)` — a registered application's
    /// container answers with its host lane here, which is what a caller
    /// asking "is this one of TextEdit's?" needs and nothing more.
    public func resolve(_ raw: String) -> (attention: AmbientAttention, key: String)? {
        resolvePlace(raw).map { ($0.place.attention, $0.key) }
    }

    // MARK: - Salience

    /// Record that something referential happened to a container.
    public func noteEvidence(
        place: AmbientPlace, key: String, _ kind: ContainerEvidence,
        at now: Date = Date()
    ) {
        let id = Self.evidenceKey(place: place, key: key)
        box.withLock { $0.evidence[id, default: [:]][kind] = now }
    }

    /// The native projection of `noteEvidence(place:key:_:at:)`.
    public func noteEvidence(
        attention: AmbientAttention, key: String, _ kind: ContainerEvidence,
        at now: Date = Date()
    ) {
        noteEvidence(place: .lane(attention), key: key, kind, at: now)
    }

    /// The strongest live claim on a container, and when it was made. Nil when
    /// nothing referential has happened to it — which is a real answer, and the
    /// one that keeps a never-mentioned container out of every anaphoric pick.
    public func evidence(
        place: AmbientPlace, key: String, at now: Date = Date()
    ) -> (kind: ContainerEvidence, at: Date)? {
        let id = Self.evidenceKey(place: place, key: key)
        let stamps = box.withLock { $0.evidence[id] ?? [:] }
        let live = stamps.filter { kind, at in
            // `.touched` is world state and never expires here; the rest are
            // conversation memory — see `evidenceRetention`.
            kind == .touched || now.timeIntervalSince(at) <= Self.evidenceRetention
        }
        guard let best = live.keys.min() else { return nil }
        return (best, live[best] ?? .distantPast)
    }

    /// The native projection of `evidence(place:key:at:)`.
    public func evidence(
        attention: AmbientAttention, key: String, at now: Date = Date()
    ) -> (kind: ContainerEvidence, at: Date)? {
        evidence(place: .lane(attention), key: key, at: now)
    }

    /// Whether any selected conversation event happened after a boundary. This deliberately
    /// examines the raw per-class timestamps rather than `evidence(...)`, whose job is
    /// different: it returns the strongest class for salience.
    public func hasEvidence(
        place: AmbientPlace,
        key: String,
        kinds: Set<ContainerEvidence>,
        newerThan boundary: Date,
        at now: Date = Date()
    ) -> Bool {
        let id = Self.evidenceKey(place: place, key: key)
        let stamps = box.withLock { $0.evidence[id] ?? [:] }
        return stamps.contains { kind, stamp in
            guard kinds.contains(kind), stamp > boundary else { return false }
            return kind == .touched
                || now.timeIntervalSince(stamp) <= Self.evidenceRetention
        }
    }

    /// The native projection of `hasEvidence(place:key:kinds:newerThan:at:)`.
    public func hasEvidence(
        attention: AmbientAttention,
        key: String,
        kinds: Set<ContainerEvidence>,
        newerThan boundary: Date,
        at now: Date = Date()
    ) -> Bool {
        hasEvidence(
            place: .lane(attention), key: key, kinds: kinds,
            newerThan: boundary, at: now)
    }

    /// SALIENCE AS A RANK — 0 is most salient, nil is no evidence at all. Class first, recency
    /// second.
    public func salienceRanks(
        place: AmbientPlace, keys: [String], at now: Date = Date()
    ) -> [String: Int] {
        let scored: [(key: String, kind: ContainerEvidence, at: Date)] = keys.compactMap { key in
            guard let found = evidence(place: place, key: key, at: now) else { return nil }
            return (key, found.kind, found.at)
        }
        let ordered = scored.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind : $0.at > $1.at
        }
        // AN UNBREAKABLE TIE IS NOT A RANK. Two containers with the same class AND the same
        // instant are indistinguishable, and handing one of them rank 0 is a coin toss wearing a
        // number.
        let tied = Set(
            ordered.filter { row in
                ordered.contains { $0.key != row.key && $0.kind == row.kind && $0.at == row.at }
            }.map(\.key))
        return Dictionary(
            uniqueKeysWithValues: ordered
                .filter { !tied.contains($0.key) }
                .enumerated().map { ($1.key, $0) })
    }

    /// The native projection of `salienceRanks(place:keys:at:)`.
    public func salienceRanks(
        attention: AmbientAttention, keys: [String], at now: Date = Date()
    ) -> [String: Int] {
        salienceRanks(place: .lane(attention), keys: keys, at: now)
    }

    /// A CORRECTION, RECORDED BOTH WAYS. Promoting the intended container is half the job. The
    /// other half is DEMOTING the rejected one.
    public func noteCorrection(
        place: AmbientPlace, rejected: String?, intended: String,
        at now: Date = Date()
    ) {
        let intendedKey = Self.evidenceKey(place: place, key: intended)
        box.withLock { state in
            if let rejected {
                state.evidence.removeValue(
                    forKey: Self.evidenceKey(place: place, key: rejected))
            }
            state.evidence[intendedKey, default: [:]][.corrected] = now
        }
    }

    /// The native projection of `noteCorrection(place:rejected:intended:at:)`.
    public func noteCorrection(
        attention: AmbientAttention, rejected: String?, intended: String,
        at now: Date = Date()
    ) {
        noteCorrection(place: .lane(attention), rejected: rejected, intended: intended, at: now)
    }

    /// `textedit|/tmp/todo.txt` / `other_apps:sketch|canvas-1`. The place
    /// token IS the raw value for every native world, so built-in evidence
    /// keys are byte-identical to what the world-keyed ledger stored.
    public static func evidenceKey(place: AmbientPlace, key: String) -> String {
        "\(place.token)|\(key)"
    }

    /// The native projection of `evidenceKey(place:key:)`.
    public static func evidenceKey(attention: AmbientAttention, key: String) -> String {
        evidenceKey(place: .lane(attention), key: key)
    }

    // MARK: - Listings

    /// Remember the order a listing binding just showed the model.
    public func noteListing(place: AmbientPlace, keys: [String], at now: Date = Date()) {
        box.withLock { state in
            state.listings[place] = ContainerListing(place: place, keys: keys, at: now)
            // A LISTING IS WHAT "SHOWN" MEANS — the model was handed these rows and can refer to them.
            // Recorded here rather than at handle-minting time, because minting happens on every turn
            // for every candidate and would give the whole roster identical evidence.
            for key in keys {
                state.evidence[Self.evidenceKey(place: place, key: key), default: [:]][.shown] = now
            }
        }
    }

    /// The native projection of `noteListing(place:keys:at:)`.
    public func noteListing(attention: AmbientAttention, keys: [String], at now: Date = Date()) {
        noteListing(place: .lane(attention), keys: keys, at: now)
    }

    /// The last listing for a place, IF IT IS STILL TRUE. A listing goes stale the moment the
    /// place's live enumeration disagrees with it — in membership OR in order.
    public func listing(
        for place: AmbientPlace, against live: [String]
    ) -> ContainerListing? {
        guard let listing = box.withLock({ $0.listings[place] }) else { return nil }
        guard listing.keys == live else { return nil }
        return listing
    }

    /// The native projection of `listing(for:against:)`.
    public func listing(
        for attention: AmbientAttention, against live: [String]
    ) -> ContainerListing? {
        listing(for: .lane(attention), against: live)
    }

    /// The raw remembered listing, staleness unchecked — for the debugger pane
    /// and for tests. Callers deciding anything must use `listing(for:against:)`.
    public func lastListing(for place: AmbientPlace) -> ContainerListing? {
        box.withLock { $0.listings[place] }
    }

    /// The native projection of `lastListing(for:)`.
    public func lastListing(for attention: AmbientAttention) -> ContainerListing? {
        lastListing(for: .lane(attention))
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
