//
//  MaryEmbeddings.swift
//  MaryBrain
//
//  WHAT: THE ONE PLACE MARY CHOOSES AN EMBEDDING STRATEGY.
//  IN:   every scope listed in the roster below
//  OUT:  a vectorizer per scope, and one warmed vector per turn
//  PIN:  NO OTHER FILE MAY PICK AN ENGINE. Before this existed the choice was
//        spelled `NLAmbientTextVectorizer.shared` in two install sites and
//        implied in a dozen more, so "what does Mary embed with, and where"
//        could only be answered by reading the whole tree. Tune here.
//
import MaryAmbient
import Foundation
import os

/// # Where embeddings are used in Mary
///
/// Keep this roster current — it is the map the PIN above promises.
///
/// ## Brain — routing corpora (built at registry reload, off the turn path)
/// Built together in `AbilityLibrary+PackageLifecycle.reload()`.
/// - `SemanticIntentIndex` — package `intentSeeds` → the turn's intent.
/// - `SemanticAbilityRequestIndex` — triggers/aliases/habits/fixtures →
///   which Abilities the words ask for, and (via `discipline(in:)`) which craft.
/// - `SemanticSkillRequestIndex` — per-Skill corpus → skill affinities and the
///   no-model confidence dispatch.
/// - `SemanticSeedFamilyIndex` — `seedFamilies` → the transform/offer family.
///
/// ## Brain — the learning loop
/// - `RoutingHabitStore` re-scores text recalled from personal Totem memory
///   (`RoutingHabitMemory`). Totem ranks in ITS space; the recalled text is
///   re-vectorized here so it can be compared against the corpora above.
///
/// ## Ambient — what is on screen (installed in `MaryRuntime`)
/// - `AmbientElementIndexStore` — element `embedTexts`, corpus AND query, with
///   its own 512-entry LRU.
/// - `AmbientAddressProbe` — "did they address an app by what it is showing".
/// - `AmbientReferenceGate` — hybrid semantic/lexical element ranking.
/// - `AffordanceProbe` — "does the screen already offer this".
///
/// ## Not here
/// - Totem search embeds server-side (`TotemDirectClient.search`), and its
///   proto accepts a client-side `query_embedding` Mary does not yet send.
/// - Seer chat/complete/vision are GENERATION, a different seam entirely.
public enum MaryEmbeddings {

    // MARK: - Engines

    /// Who made a vector. CARRIED, NOT ASSUMED: two engines share no space, and
    /// `AmbientVectorMath.dot` answers a dimension mismatch with −1 — a silent
    /// "nothing matches" that would look like an empty corpus rather than a bug.
    public enum Engine: Sendable, Equatable {
        /// Apple's on-device `NLEmbedding`. Synchronous and free; absent on a
        /// machine without the English asset, which is the whole reason the
        /// tier below exists.
        case appleNL
        /// Seer's `/v1/embed`. Asynchronous, so it can only fill the turn memo
        /// ahead of scoring — never satisfy a synchronous read.
        case seer(model: String)

        public var id: String {
            switch self {
            case .appleNL: return "apple-nl"
            case .seer(let model): return "seer:\(model)"
            }
        }

        public var isSynchronous: Bool {
            if case .appleNL = self { return true }
            return false
        }
    }

    // MARK: - Strategy

    /// THE TUNING SURFACE. One line per decision; nothing else chooses.
    ///
    /// Apple's model is preferred wherever it exists: it is synchronous, free,
    /// and every index and probe is already calibrated against it. Seer is the
    /// tier underneath — same vendor as Totem's own embeddings, so a machine
    /// with no local asset still routes semantically instead of abstaining.
    public static func engine() -> Engine? {
        if NLAmbientTextVectorizer.shared != nil { return .appleNL }
        if let model = seerModel.withLock({ $0 }) { return .seer(model: model) }
        return nil
    }

    /// Set when a Seer embedding backend is installed and reachable.
    private static let seerModel = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let backend = OSAllocatedUnfairLock<(any SeerEmbeddingProviding)?>(
        initialState: nil)

    /// Installed by the runtime once the stack is configured.
    public static func installSeerBackend(
        _ provider: any SeerEmbeddingProviding, model: String
    ) {
        backend.withLock { $0 = provider }
        seerModel.withLock { $0 = model.isEmpty ? "mistral-embed" : model }
    }

    // MARK: - The turn memo

    /// One warmed vector per turn, filled asynchronously before anything scores.
    ///
    /// THIS IS WHAT MAKES A NETWORK ENGINE POSSIBLE AT ALL. Every consumer —
    /// `TurnTriage.verdict`, `AmbientEngine.resolve`, `namedDiscipline`,
    /// `namesTransform` — is synchronous to the top of the turn, so a vector
    /// that needs an await must already be here when they run.
    ///
    /// It also pays for itself under Apple's model: the same first line was
    /// being vectorized at least four separate times a turn, memoized nowhere.
    private static let memo = OSAllocatedUnfairLock<[String: [Float]]>(initialState: [:])

    /// Embed this turn's words ahead of scoring. Safe to call with no engine,
    /// and safe to call twice.
    public static func warm(_ text: String) async {
        let line = RoutingQuery.firstLine(text)
        guard !line.isEmpty, memo.withLock({ $0[line] }) == nil else { return }
        switch engine() {
        case .appleNL:
            guard let vector = NLAmbientTextVectorizer.shared?.vector(for: line) else { return }
            memo.withLock { $0[line] = vector }
        case .seer:
            guard let provider = backend.withLock({ $0 }),
                  let batch = try? await provider.embed([line]),
                  let vector = batch.vectors.first
            else { return }
            memo.withLock { $0[line] = vector }
        case nil:
            return
        }
    }

    /// Drop the turn's warmed vectors. Called from `AbilityRuntime.beginTurn`,
    /// beside the other per-turn memos.
    public static func endTurn() {
        memo.withLock { $0.removeAll(keepingCapacity: true) }
    }

    /// The vectorizer every index and probe should be built with.
    public static func vectorizer() -> (any AmbientTextVectorizer)? {
        guard let engine = engine() else { return nil }
        return ManagedVectorizer(engine: engine, backend: backend.withLock { $0 })
    }

    /// Sync read over an async fill.
    ///
    /// A MISS IS A NIL, NEVER A GUESS. Every consumer already fail-closes on
    /// nil — that contract is what lets a network engine sit behind a
    /// synchronous protocol without blocking a turn or inventing a vector.
    struct ManagedVectorizer: AmbientTextVectorizer {
        let engine: Engine
        let backend: (any SeerEmbeddingProviding)?

        func vector(for text: String) -> [Float]? {
            let line = RoutingQuery.firstLine(text)
            if let warmed = MaryEmbeddings.memo.withLock({ $0[line] }) { return warmed }
            // Apple's model is cheap enough to compute inline on a miss; a
            // network round trip is not, so an unwarmed text simply abstains.
            guard case .appleNL = engine else { return nil }
            guard let vector = NLAmbientTextVectorizer.shared?.vector(for: line) else { return nil }
            MaryEmbeddings.memo.withLock { $0[line] = vector }
            return vector
        }
    }
}
