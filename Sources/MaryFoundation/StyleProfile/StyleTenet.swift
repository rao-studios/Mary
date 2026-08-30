//
//  StyleTenet.swift
//  MaryFoundation
//
//  WHAT: One portable learned craft fact — dimension, value, scope, evidence.
//  IN:   corpus observer / StyleProfile.tenets.
//  OUT:  StyleRendering, StyleProfileCodec import.
//  PIN:  Format version, StyleHashing, counter-evidence, StyleProvenance.
//

import Foundation

/// Origin. Decides whether the tenet may render.
public enum StyleProvenance: Codable, Hashable, Sendable {
    /// This machine's corpus and edit reactions.
    case observed
    /// Stated by hand here. Outranks observation; observer still counts underneath.
    case asserted
    /// Imported. Inspectable, inert until local evidence promotes it.
    case imported(from: String)

    public var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }

    public var isAsserted: Bool {
        if case .asserted = self { return true }
        return false
    }

    /// Observed or asserted here. Trust boundary for model reach.
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
    /// Scope identity (`swift`, AbilityID, path). Same ids as packages/Totem.
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

    /// Project root when kind is `.project`.
    public var projectID: String? {
        kind == .project ? identity : nil
    }

    /// AbilityID when kind is `.ability`.
    public var abilityID: AbilityID? {
        guard kind == .ability, let identity else { return nil }
        return AbilityID(identity)
    }

    /// Owner-free key component. Identity on every rung prevents collisions.
    public var keyComponent: String {
        "\(kind.rawValue):\(StyleHashing.canonical(identity ?? ""))"
    }

    /// Display noun for this scope.
    public var displayName: String {
        guard let identity, !identity.isEmpty else { return kind.rawValue }
        if kind == .project { return (identity as NSString).lastPathComponent }
        return identity.prefix(1).uppercased() + identity.dropFirst()
    }

    enum CodingKeys: String, CodingKey {
        case kind, identity
    }

    /// Empty identity → nil. Unidentified scope stays inert (`isMeaningful`).
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
    /// Corpus/kept-edit agreements.
    public var support: Int
    /// Disagreements (other corpus value, reverted edit).
    public var counter: Int
    public var confidence: Double
    public var status: StyleStatus
    public var provenance: StyleProvenance
    public var lastObservedAt: Date
    /// `roleVocabulary` words. Sorted for digest.
    public var vocabulary: [String]
    /// Inspector only. Never brief, never model.
    public var statement: String?
    /// Synthesized illustration. Never user source.
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

    /// Forward-tolerant keyed decode. Unknown keys ignored; missing required still fail.
    /// PIN: throw-on-unknown would empty the store on rollback.
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

    /// Owner-free key: scope + dimension. TotemMemoryTopology adds owner at place.
    public var tenetKey: String {
        StyleHashing.canonical("\(scope.keyComponent)|\(dimension.rawValue)")
    }

    /// This build understands the pairing. Newer-Mary tenets stay inert.
    public var isMeaningful: Bool {
        guard formatVersion <= Self.currentFormatVersion else { return false }
        guard dimension != .unknown, scope.kind != .unknown else { return false }
        // Unidentified scope is malformed; stay quiet.
        guard scope.identity?.isEmpty == false else { return false }
        if dimension == .roleVocabulary { return !vocabulary.isEmpty }
        return value != .unknown && dimension.accepts(value)
    }

    /// May render: meaningful + local. Observed needs verified; asserted does not.
    public var isRenderable: Bool {
        guard isMeaningful, provenance.isLocal else { return false }
        // Assertion has no freshness.
        if provenance.isAsserted { return true }
        // Age is in tallies' decay floor, not here.
        return status == .verified
    }

    /// Agreeing evidence fraction.
    public var agreement: Double {
        let total = support + counter
        return total == 0 ? 0 : Double(support) / Double(total)
    }
}
