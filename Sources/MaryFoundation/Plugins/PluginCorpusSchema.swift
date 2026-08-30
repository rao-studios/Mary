//
//  PluginCorpusSchema.swift
//  MaryFoundation
//
//  WHAT: Project-on-disk coordinates so a generic producer can learn craft over time.
//  IN:   PluginSchema.corpus / MaryAbilityPackage.corpus.
//  OUT:  PluginCorpusStructureSchema, PluginValidator+Corpus, StyleDimension.
//  PIN:  Named `corpus` not `codeCorpus` — notation-agnostic.
//

import Foundation

// MARK: - Where a rule looks

/// Which slice a counter reads. PIN: producer masks comments vs code once per file.
public enum PluginCorpusRegion: String, Codable, Hashable, Sendable, CaseIterable {
    /// Everything outside comments and string literals.
    case code
    /// Only the comments.
    case comments
    /// The unmasked file, for rules whose subject spans both.
    case source
    /// The file's own name, for conventions carried by naming.
    case filename
}

// MARK: - What a rule counts

/// Closed counter kinds. No general expression language.
public struct PluginCorpusCounter: Codable, Hashable, Sendable {

    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        /// Occurrences of `pattern` inside `region`.
        case pattern
        /// Declared type names ending in `tokens`. Uses declarations relation.
        case declaredTypeSuffix
        /// Pattern capture names a type declared in this file.
        case selfReference
        /// Type count via declarations relation. Not functions/properties.
        case declaration
        /// File size in bytes. Guard: large enough that organisation is a choice.
        case fileBytes
    }

    public var source: Source
    /// Required by `.pattern` and `.selfReference`; ignored otherwise.
    public var pattern: String?
    public var region: PluginCorpusRegion
    /// Required by `.declaredTypeSuffix`; ignored otherwise.
    public var tokens: [String]

    public init(
        source: Source,
        pattern: String? = nil,
        region: PluginCorpusRegion = .code,
        tokens: [String] = []
    ) {
        self.source = source
        self.pattern = pattern
        self.region = region
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case pattern
        case region
        case tokens
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(Source.self, forKey: .source)
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern)
        region = try values.decodeIfPresent(PluginCorpusRegion.self, forKey: .region) ?? .code
        tokens = try values.decodeIfPresent([String].self, forKey: .tokens) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        if let pattern { try container.encode(pattern, forKey: .pattern) }
        if region != .code { try container.encode(region, forKey: .region) }
        if !tokens.isEmpty { try container.encode(tokens, forKey: .tokens) }
    }
}

// MARK: - When a rule is allowed to speak

/// Guard: failing files abstain. Silence is a result.
public struct PluginCorpusGuard: Codable, Hashable, Sendable {
    public var numerator: PluginCorpusCounter
    /// Absent makes this an absolute-count guard rather than a ratio.
    public var denominator: PluginCorpusCounter?
    /// The guard passes when the value is at least this.
    public var atLeast: Double

    public init(
        numerator: PluginCorpusCounter,
        denominator: PluginCorpusCounter? = nil,
        atLeast: Double
    ) {
        self.numerator = numerator
        self.denominator = denominator
        self.atLeast = atLeast
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case numerator
        case denominator
        case atLeast
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        numerator = try values.decode(PluginCorpusCounter.self, forKey: .numerator)
        denominator = try values.decodeIfPresent(
            PluginCorpusCounter.self, forKey: .denominator)
        atLeast = try values.decode(Double.self, forKey: .atLeast)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        if let denominator { try container.encode(denominator, forKey: .denominator) }
        try container.encode(atLeast, forKey: .atLeast)
    }
}

// MARK: - One candidate in a vote

/// A value a file might be evidence for, and the counters that measure it.
public struct PluginCorpusCandidate: Codable, Hashable, Sendable {
    /// StyleValue raw value. Validated against the known set.
    public var value: String
    /// Summed counters for one habit spelling.
    public var counters: [PluginCorpusCounter]
    /// Per-candidate evidence floor. Below it, score zero.
    public var minimum: Int

    public init(value: String, counters: [PluginCorpusCounter], minimum: Int = 0) {
        self.value = value
        self.counters = counters
        self.minimum = minimum
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case counters
        case minimum
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decode(String.self, forKey: .value)
        counters = try values.decode([PluginCorpusCounter].self, forKey: .counters)
        minimum = try values.decodeIfPresent(Int.self, forKey: .minimum) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(counters, forKey: .counters)
        if minimum != 0 { try container.encode(minimum, forKey: .minimum) }
    }
}

// MARK: - A style rule

/// One dimension's question, and how this notation answers it.
public struct PluginCorpusStyleRule: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Leader wins. Tie is silence.
        case vote
        /// Two counters vs threshold. Omit a side to abstain.
        case ratio
        /// Emit matched role tokens. `roleVocabulary` only.
        case vocabulary
    }

    /// A `StyleDimension` raw value; validated against the known set.
    public var dimension: String
    public var kind: Kind
    /// Files that fail this abstain entirely.
    public var guardCondition: PluginCorpusGuard?

    /// `.vote` only.
    public var candidates: [PluginCorpusCandidate]

    /// `.ratio` only.
    public var numerator: PluginCorpusCounter?
    public var denominator: PluginCorpusCounter?
    public var threshold: Double?
    public var above: String?
    public var below: String?

    /// `.vocabulary` only.
    public var vocabulary: PluginCorpusCounter?

    public init(
        dimension: String,
        kind: Kind,
        guardCondition: PluginCorpusGuard? = nil,
        candidates: [PluginCorpusCandidate] = [],
        numerator: PluginCorpusCounter? = nil,
        denominator: PluginCorpusCounter? = nil,
        threshold: Double? = nil,
        above: String? = nil,
        below: String? = nil,
        vocabulary: PluginCorpusCounter? = nil
    ) {
        self.dimension = dimension
        self.kind = kind
        self.guardCondition = guardCondition
        self.candidates = candidates
        self.numerator = numerator
        self.denominator = denominator
        self.threshold = threshold
        self.above = above
        self.below = below
        self.vocabulary = vocabulary
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case dimension
        case kind
        // Wire key `guard`; Swift keyword so CodingKeys maps it.
        case guardCondition = "guard"
        case candidates
        case numerator
        case denominator
        case threshold
        case above
        case below
        case vocabulary
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try values.decode(String.self, forKey: .dimension)
        kind = try values.decode(Kind.self, forKey: .kind)
        guardCondition = try values.decodeIfPresent(
            PluginCorpusGuard.self, forKey: .guardCondition)
        candidates = try values.decodeIfPresent(
            [PluginCorpusCandidate].self, forKey: .candidates) ?? []
        numerator = try values.decodeIfPresent(PluginCorpusCounter.self, forKey: .numerator)
        denominator = try values.decodeIfPresent(
            PluginCorpusCounter.self, forKey: .denominator)
        threshold = try values.decodeIfPresent(Double.self, forKey: .threshold)
        above = try values.decodeIfPresent(String.self, forKey: .above)
        below = try values.decodeIfPresent(String.self, forKey: .below)
        vocabulary = try values.decodeIfPresent(PluginCorpusCounter.self, forKey: .vocabulary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(kind, forKey: .kind)
        if let guardCondition { try container.encode(guardCondition, forKey: .guardCondition) }
        if !candidates.isEmpty { try container.encode(candidates, forKey: .candidates) }
        if let numerator { try container.encode(numerator, forKey: .numerator) }
        if let denominator { try container.encode(denominator, forKey: .denominator) }
        if let threshold { try container.encode(threshold, forKey: .threshold) }
        if let above { try container.encode(above, forKey: .above) }
        if let below { try container.encode(below, forKey: .below) }
        if let vocabulary { try container.encode(vocabulary, forKey: .vocabulary) }
    }
}

// MARK: - Relationships between units

/// Crawl edges: reference, ancestry, declaration. No fourth.
public struct PluginCorpusRelations: Codable, Hashable, Sendable {
    /// Captures the name of something this unit depends on — one hop.
    public var references: [String]
    /// Ancestry/conformance name — second hop.
    public var ancestry: [String]
    /// Declared name. Index for references and selfReference counters.
    public var declarations: [String]

    public init(references: [String] = [], ancestry: [String] = [], declarations: [String] = []) {
        self.references = references
        self.ancestry = ancestry
        self.declarations = declarations
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case references
        case ancestry
        case declarations
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        references = try values.decodeIfPresent([String].self, forKey: .references) ?? []
        ancestry = try values.decodeIfPresent([String].self, forKey: .ancestry) ?? []
        declarations = try values.decodeIfPresent([String].self, forKey: .declarations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !references.isEmpty { try container.encode(references, forKey: .references) }
        if !ancestry.isEmpty { try container.encode(ancestry, forKey: .ancestry) }
        if !declarations.isEmpty { try container.encode(declarations, forKey: .declarations) }
    }
}

// MARK: - How much a crawl may take

/// Crawl caps. A sixty-file crawl is a worse answer than eight.
public struct PluginCorpusBudgets: Codable, Hashable, Sendable {
    public var maximumFiles: Int
    public var maximumEdges: Int
    public var maximumFileBytes: Int

    public init(maximumFiles: Int = 24, maximumEdges: Int = 120, maximumFileBytes: Int = 400_000) {
        self.maximumFiles = maximumFiles
        self.maximumEdges = maximumEdges
        self.maximumFileBytes = maximumFileBytes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case maximumFiles
        case maximumEdges
        case maximumFileBytes
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PluginCorpusBudgets()
        maximumFiles = try values.decodeIfPresent(Int.self, forKey: .maximumFiles)
            ?? fallback.maximumFiles
        maximumEdges = try values.decodeIfPresent(Int.self, forKey: .maximumEdges)
            ?? fallback.maximumEdges
        maximumFileBytes = try values.decodeIfPresent(Int.self, forKey: .maximumFileBytes)
            ?? fallback.maximumFileBytes
    }
}

// MARK: - The block

/// One application's project shape, as its package describes it.
public struct PluginCorpusSchema: Codable, Hashable, Sendable {

    /// Unit extensions without the dot. Empty invalid unless `structure` (manifest, not crawl).
    public var include: [String]
    /// Directory names never walked (build products, vendored).
    public var exclude: [String]
    /// Root markers (`Package.swift`, `.xcodeproj`). Dot-names match as suffix.
    /// Empty = containing folder. AXDocument is the file, not the workspace.
    public var projectMarkers: [String]
    /// Notation name for style scope (`swift`, `markdown`, `prose`).
    public var notation: String
    public var relations: PluginCorpusRelations
    public var style: [PluginCorpusStyleRule]
    public var budgets: PluginCorpusBudgets

    /// On-disk project shape. Absent = notation-only. See PluginCorpusStructureSchema.
    public var structure: PluginCorpusStructureSchema?

    /// Window naming of root and focused file. See PluginWorkspaceIdentitySchema.
    public var workspaceIdentity: PluginWorkspaceIdentitySchema

    /// CLI templates for build/test. Absent → backend from projectMarkers.
    public var build: PluginProjectBuildSchema?

    public init(
        include: [String],
        exclude: [String] = [],
        projectMarkers: [String] = [],
        notation: String,
        relations: PluginCorpusRelations = .init(),
        style: [PluginCorpusStyleRule] = [],
        budgets: PluginCorpusBudgets = .init(),
        structure: PluginCorpusStructureSchema? = nil,
        workspaceIdentity: PluginWorkspaceIdentitySchema = .default,
        build: PluginProjectBuildSchema? = nil
    ) {
        self.include = include
        self.exclude = exclude
        self.projectMarkers = projectMarkers
        self.notation = notation
        self.relations = relations
        self.style = style
        self.budgets = budgets
        self.structure = structure
        self.workspaceIdentity = workspaceIdentity
        self.build = build
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case include
        case exclude
        case projectMarkers
        case notation
        case relations
        case style
        case budgets
        case structure
        case workspaceIdentity
        case build
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        include = try values.decodeIfPresent([String].self, forKey: .include) ?? []
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
        projectMarkers = try values.decodeIfPresent(
            [String].self, forKey: .projectMarkers) ?? []
        notation = try values.decode(String.self, forKey: .notation)
        relations = try values.decodeIfPresent(
            PluginCorpusRelations.self, forKey: .relations) ?? .init()
        style = try values.decodeIfPresent([PluginCorpusStyleRule].self, forKey: .style) ?? []
        budgets = try values.decodeIfPresent(
            PluginCorpusBudgets.self, forKey: .budgets) ?? .init()
        structure = try values.decodeIfPresent(
            PluginCorpusStructureSchema.self, forKey: .structure)
        workspaceIdentity = try values.decodeIfPresent(
            PluginWorkspaceIdentitySchema.self, forKey: .workspaceIdentity) ?? .default
        build = try values.decodeIfPresent(
            PluginProjectBuildSchema.self, forKey: .build)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !include.isEmpty { try container.encode(include, forKey: .include) }
        if !exclude.isEmpty { try container.encode(exclude, forKey: .exclude) }
        if !projectMarkers.isEmpty {
            try container.encode(projectMarkers, forKey: .projectMarkers)
        }
        try container.encode(notation, forKey: .notation)
        if relations != PluginCorpusRelations() {
            try container.encode(relations, forKey: .relations)
        }
        if !style.isEmpty { try container.encode(style, forKey: .style) }
        if budgets != PluginCorpusBudgets() { try container.encode(budgets, forKey: .budgets) }
        if let structure { try container.encode(structure, forKey: .structure) }
        if workspaceIdentity != .default {
            try container.encode(workspaceIdentity, forKey: .workspaceIdentity)
        }
        if let build { try container.encode(build, forKey: .build) }
    }
}
