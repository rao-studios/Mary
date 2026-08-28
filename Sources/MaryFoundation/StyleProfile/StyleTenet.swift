//
//  StyleTenet.swift
//  MaryFoundation
//
//  One learned thing about how a person works, in a form that can travel.
//
//  It generalizes `ApplicationSchemaFact`'s proven mechanics — support counts,
//  candidate→verified promotion, confidence, an age horizon — and fixes what
//  that type could not carry:
//
//    · A FORMAT VERSION, from the first commit. `ApplicationSchemaFact` has
//      none and its loader swallows decode failures with `try?`, so adding one
//      later would not be an error, it would be silent total amnesia.
//    · ONE canonicalizer and ONE hash (`StyleHashing`). Three canonicalizers
//      already exist across the indexing surface and they disagree about
//      punctuation and empty input; a key minted on one machine and resolved
//      on another cannot be built on a coin flip.
//    · COUNTER-EVIDENCE. That type's confidence is a monotonic ratchet whose
//      only downward pressure is a 45-day sweep, so an idiom you have outgrown
//      keeps its confidence until the code itself changes.
//    · PROVENANCE. Observed here, or imported from elsewhere — the field that
//      decides whether a tenet may be rendered at all.
//

import Foundation

/// Where a tenet came from, and therefore whether it may speak.
public enum StyleProvenance: Codable, Hashable, Sendable {
    /// Learned from this owner's own corpus and their reactions to Mary's
    /// edits, on this machine.
    case observed
    /// Stated by hand, on this machine, on purpose.
    ///
    /// It OUTRANKS observation, and that asymmetry is the point: an assertion
    /// is a statement of intent, while observation is an inference from code
    /// that may predate the intent. So it renders immediately without waiting
    /// for support, it is never demoted by contrary evidence, and it wins a
    /// conflict. The observer keeps counting underneath, so a disagreement
    /// between what you say and what you have written stays visible instead of
    /// being resolved away.
    case asserted
    /// Carried in from another profile. Inspectable, inert, and NEVER
    /// rendered into a brief — local evidence has to promote it first. This
    /// is consent without a dialog: an imported tenet cannot influence a
    /// single line of code until this machine has independently seen the same
    /// thing.
    case imported(from: String)

    public var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }

    public var isAsserted: Bool {
        if case .asserted = self { return true }
        return false
    }

    /// Learned or stated here, as opposed to handed over. The trust boundary
    /// that decides whether a tenet may reach a model.
    public var isLocal: Bool { isObserved || isAsserted }
}

public enum StyleStatus: String, Codable, Hashable, Sendable {
    case candidate
    case verified
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleStatus(rawValue: raw) ?? .unknown
    }
}

public struct StyleScope: Codable, Hashable, Sendable {
    public var kind: StyleScopeKind
    /// WHAT this scope is about: `"swift"`, `"design"`, `"sketch"`,
    /// `"/work/Repo"`. For `.ability` it is an `AbilityID` raw value — the
    /// same identifier packages declare and Totem deposits, never a second
    /// vocabulary invented for this layer.
    public var identity: String?

    public init(kind: StyleScopeKind, identity: String? = nil) {
        self.kind = kind
        self.identity = identity.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func language(_ id: String) -> StyleScope {
        StyleScope(kind: .language, identity: id)
    }

    public static func ability(_ id: AbilityID) -> StyleScope {
        StyleScope(kind: .ability, identity: id.rawValue)
    }

    public static func application(_ id: String) -> StyleScope {
        StyleScope(kind: .application, identity: id)
    }

    public static func project(_ id: String) -> StyleScope {
        StyleScope(kind: .project, identity: id)
    }

    /// The project root, for `.project` scopes. Kept as a named reader
    /// because callers ask that question specifically and `identity` alone
    /// would not say which question was being asked.
    public var projectID: String? {
        kind == .project ? identity : nil
    }

    /// The Ability this scope names, for `.ability` scopes.
    public var abilityID: AbilityID? {
        guard kind == .ability, let identity else { return nil }
        return AbilityID(identity)
    }

    /// The scope's contribution to the tenet key. Owner-free by construction,
    /// and identity-bearing on every rung — which is what keeps two
    /// applications, two languages, or two Abilities from colliding on one key.
    public var keyComponent: String {
        "\(kind.rawValue):\(StyleHashing.canonical(identity ?? ""))"
    }

    /// How this scope reads in a sentence: "Swift", "Xcode", "Mary".
    public var displayName: String {
        guard let identity, !identity.isEmpty else { return kind.rawValue }
        if kind == .project { return (identity as NSString).lastPathComponent }
        return identity.prefix(1).uppercased() + identity.dropFirst()
    }

    enum CodingKeys: String, CodingKey {
        case kind, identity
    }

    /// An absent or empty identity decodes as nil rather than as "".
    ///
    /// `isMeaningful` refuses an un-identified scope, so this is the shape a
    /// malformed rung arrives in and the tenet stays inert — acting on "some
    /// application, we don't know which" is worse than saying nothing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(StyleScopeKind.self, forKey: .kind)
        identity = try container
            .decodeIfPresent(String.self, forKey: .identity)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(identity, forKey: .identity)
    }
}

public struct StyleTenet: Codable, Hashable, Sendable, Identifiable {

    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var dimension: StyleDimension
    public var value: StyleValue
    public var scope: StyleScope
    /// Times the corpus or a kept edit agreed with this choice.
    public var support: Int
    /// Times something disagreed — the other value in the corpus, or an edit
    /// the user reverted or rewrote.
    public var counter: Int
    public var confidence: Double
    public var status: StyleStatus
    public var provenance: StyleProvenance
    public var lastObservedAt: Date
    /// Bounded word list for `roleVocabulary`. Sorted so the encoding is
    /// reproducible.
    public var vocabulary: [String]
    /// INSPECTOR METADATA ONLY. Never rendered into a brief, never given to a
    /// model, on either side of a transfer.
    public var statement: String?
    /// A SYNTHESIZED illustration — never an excerpt of the user's code.
    /// Portability forbids source text, which is exactly what lets a profile
    /// be handed to someone without handing them the code it was learned from.
    public var illustration: String?

    public init(
        formatVersion: Int = StyleTenet.currentFormatVersion,
        dimension: StyleDimension,
        value: StyleValue,
        scope: StyleScope,
        support: Int = 1,
        counter: Int = 0,
        confidence: Double = 0.5,
        status: StyleStatus = .candidate,
        provenance: StyleProvenance = .observed,
        lastObservedAt: Date = Date(),
        vocabulary: [String] = [],
        statement: String? = nil,
        illustration: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.dimension = dimension
        self.value = value
        self.scope = scope
        self.support = max(0, support)
        self.counter = max(0, counter)
        self.confidence = min(1, max(0, confidence))
        self.status = status
        self.provenance = provenance
        self.lastObservedAt = lastObservedAt
        self.vocabulary = Array(Set(vocabulary.filter { !$0.isEmpty })).sorted()
        self.statement = statement
        self.illustration = illustration
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, dimension, value, scope, support, counter
        case confidence, status, provenance, lastObservedAt, vocabulary
        case statement, illustration
    }

    /// TOLERANT ON THE WAY IN — and the direction that matters is FORWARD.
    ///
    /// A tenet written by a NEWER build carries keys this one has never heard
    /// of, and a keyed container ignores them rather than throwing. That is the
    /// same rollback protection `StyleDimension`'s header argues for and
    /// `docs/TOTEM-MERGE.md` paid for: running yesterday's binary after
    /// today's is a development hazard, and a throw there re-seeds the store
    /// empty rather than skipping one row.
    ///
    /// Written out by hand because the synthesized decode is tolerant only for
    /// Optionals — a plain non-optional field would fail with `keyNotFound`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        dimension = try container.decode(StyleDimension.self, forKey: .dimension)
        value = try container.decode(StyleValue.self, forKey: .value)
        scope = try container.decode(StyleScope.self, forKey: .scope)
        support = try container.decode(Int.self, forKey: .support)
        counter = try container.decode(Int.self, forKey: .counter)
        confidence = try container.decode(Double.self, forKey: .confidence)
        status = try container.decode(StyleStatus.self, forKey: .status)
        provenance = try container.decode(StyleProvenance.self, forKey: .provenance)
        lastObservedAt = try container.decode(Date.self, forKey: .lastObservedAt)
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        statement = try container.decodeIfPresent(String.self, forKey: .statement)
        illustration = try container.decodeIfPresent(String.self, forKey: .illustration)
    }

    public var id: String { tenetKey }

    /// THE OWNER-FREE LOGICAL KEY. No owner, no machine, no node — scope and
    /// dimension only. Placement adds the owner (`TotemMemoryTopology`);
    /// identity never carries it, which is what lets the same tenet be
    /// re-addressed under a different owner without becoming a different
    /// thing.
    public var tenetKey: String {
        StyleHashing.canonical("\(scope.keyComponent)|\(dimension.rawValue)")
    }

    /// True when this build knows what the tenet is talking about AND the
    /// pairing is legal. A tenet from a newer Mary decodes and is retained,
    /// but answers false here and is invisible everywhere downstream.
    public var isMeaningful: Bool {
        guard formatVersion <= Self.currentFormatVersion else { return false }
        guard dimension != .unknown, scope.kind != .unknown else { return false }
        // An un-identified scope is malformed: every rung carries an identity,
        // and acting on "some application, we don't know which" is worse than
        // staying quiet.
        guard scope.identity?.isEmpty == false else { return false }
        if dimension == .roleVocabulary { return !vocabulary.isEmpty }
        return value != .unknown && dimension.accepts(value)
    }

    /// May this tenet be rendered into a brief?
    ///
    /// It has to be meaningful (this build understands it) and LOCAL (learned
    /// or stated here, never handed over) — the second is the trust boundary,
    /// and an imported tenet stays inert however well signed until local
    /// evidence promotes it.
    ///
    /// Verification is required of an OBSERVED tenet and not of an asserted
    /// one, because they answer different questions. Observation needs enough
    /// support to be believed; an assertion is already the answer, and making
    /// it wait for the corpus to agree would defeat the reason for saying it.
    public var isRenderable: Bool {
        guard isMeaningful, provenance.isLocal else { return false }
        // An assertion has no freshness — it is a statement, and what you said
        // stays said however long it has been.
        if provenance.isAsserted { return true }
        // Observed evidence needs no age check HERE: a contribution past the
        // decay floor stops counting in `tallies`, so a faded row yields no
        // leader and this tenet is never minted in the first place.
        return status == .verified
    }

    /// The proportion of evidence that agreed.
    public var agreement: Double {
        let total = support + counter
        return total == 0 ? 0 : Double(support) / Double(total)
    }
}
