//
//  PluginCorpusSchema.swift
//  MaryFoundation
//
//  HOW MARY LEARNS THE SHAPE OF YOUR WORK IN THIS APPLICATION — declared, not
//  coded.
//
//  The prose surface next door says where an application's text lives so Mary
//  can READ IT NOW. This block says how an application's project on disk is
//  organised, so Mary can learn it OVER TIME: which files count, what a
//  relationship between two of them looks like, and what stylistic habits are
//  worth noticing. A generic compiled producer does the walking; the package
//  supplies the coordinates.
//
//  IT IS `corpus`, NOT `codeCorpus`, AND THE NAME IS THE DESIGN. Nothing here
//  is about code. A unit is one thing the user settled on inside a project —
//  today a source file, and with a different set of declarations a Scrivener
//  chapter or a folder of notes. `StyleDimension` already carries
//  writing-flavoured dimensions (`titlingStyle`, `sectionGranularity`,
//  `annotationHabit`) beside the code ones, because the axis was always the
//  CRAFT and never the language. Code is the first notation to declare itself,
//  not the shape of the contract.
//
//  THE PRECEDENT THIS REPLACES. The version of this feature Mary is porting
//  had an editor-shaped watcher, a language-shaped crawl, and a 410-line
//  observer full of Swift regular expressions — all compiled in, all naming
//  one application and one language. The indexing layer underneath it was
//  already generic and said so in its own header ("Xcode supplies units today;
//  a chapter is the same shape with a different producer"). Only the producer
//  was specific, and only because nothing let a package describe itself. This
//  block is that missing description.
//
//  WHAT IS DELIBERATELY ABSENT. No file paths, no shell commands, no parser
//  plug-in, no scripting. A package describes patterns over text it already
//  declares an interest in; every judgement about WHEN to look, how much to
//  read, what to send anywhere, and whether to annotate at all stays with
//  Mary.
//

import Foundation

// MARK: - Where a rule looks

/// Which slice of a file a counter reads.
///
/// THE SPLIT IS LOAD-BEARING, not a convenience. A pattern counting `throws`
/// must not match the word inside a comment explaining why something does not
/// throw, and the comment-posture rules must read ONLY comments or they
/// measure the code instead. The producer masks the two apart once per file
/// and hands each rule the slice it asked for.
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

/// One number a rule can ask the producer for.
///
/// A CLOSED SET, and short on purpose. Every counter here exists because one
/// of the ported detectors needed exactly it; a general expression language
/// would let a package ask questions Mary cannot bound the cost of, and would
/// turn a declaration into a program. Four sources cover all nine detectors.
public struct PluginCorpusCounter: Codable, Hashable, Sendable {

    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        /// Occurrences of `pattern` inside `region`.
        case pattern
        /// Declared type names ending in any of `tokens` — the role
        /// vocabulary. Needs no pattern: the corpus's own `declarations`
        /// relation already found the names.
        case declaredTypeSuffix
        /// `pattern` matches whose capture group names a type DECLARED IN
        /// THIS FILE. The one cross-reference a plain regex cannot make, and
        /// the whole of "does this author split a type across files".
        case selfReference
        /// How many declarations this file makes, via the corpus's
        /// `declarations` relation. The denominator most ratios want.
        case declaration
        /// The file's size in bytes. A guard, almost always: "is this file
        /// big enough for its organisation to be a choice rather than an
        /// accident".
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

/// A precondition on a whole rule: a file that does not meet it ABSTAINS.
///
/// SILENCE IS A RESULT. The ported detectors are emphatic about this and one
/// of them carries the scar in its comment: counting every ordinary small file
/// as a vote for "keeps a type whole" measured a codebase at 90% confident of
/// the opposite of its real convention, "because most files in any codebase
/// hold one small type — that is a fact about the language, not about the
/// author." A guard is how a package says which files actually answer its
/// question.
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
    /// A `StyleValue` raw value. Validated against the known set rather than
    /// typed here, so this schema does not have to move every time the style
    /// vocabulary grows.
    public var value: String
    /// Summed. Several counters for one value is how "any of these spellings
    /// means the same habit" is said.
    public var counters: [PluginCorpusCounter]
    /// Evidence this candidate needs before it may stand at all. Below it the
    /// candidate scores zero rather than a small number.
    ///
    /// PER CANDIDATE AND NOT PER RULE, because the alternatives in one vote
    /// are not always equally cheap to believe. "This file splits a type
    /// across files" is proven by its own name; "this file keeps a type
    /// whole" needs several of the type's own extensions in it before the
    /// file is answering the question rather than just being small.
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
        /// Count every candidate; the leader wins. A TIE IS SILENCE, never a
        /// coin flip — a file with equal evidence has no opinion.
        case vote
        /// Compare two counters. Above `threshold` votes `above`, below votes
        /// `below`; either may be omitted to abstain on that side.
        case ratio
        /// Emit the matched role tokens themselves rather than a value. Only
        /// `roleVocabulary` works this way: the answer is a vocabulary, not a
        /// choice between alternatives.
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
        // `guard` is a Swift keyword; the WIRE spelling stays the readable
        // word because a package author is writing JSON, not Swift.
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

/// The three edges a crawl can follow, as this notation spells them.
///
/// WHY THESE THREE AND NO MORE. The neighbourhood walk is "everything this
/// unit touches, one hop; what it descends from, two" — so it needs to know
/// what a reference looks like, what an ancestry looks like, and what a
/// declaration looks like so a reference can be resolved to the file that
/// declares it. A fourth edge would widen the crawl without making the
/// neighbourhood better, which is the failure the caps exist to prevent.
public struct PluginCorpusRelations: Codable, Hashable, Sendable {
    /// Captures the name of something this unit depends on — one hop.
    public var references: [String]
    /// Captures a name this unit descends from or conforms to — worth a
    /// second hop, because that is where a subtype's meaning lives.
    public var ancestry: [String]
    /// Captures a name this unit DECLARES. Builds the index every reference
    /// is resolved through, and the set `selfReference` counters test against.
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

/// The caps, declared so a notation with different economics can say so.
///
/// THESE ARE THE FEATURE, NOT A SAFETY NET — the ported crawl says it
/// outright: "a crawl that returned sixty files would be a worse answer than
/// one that returns eight, no matter how much of it was true." The defaults
/// are the measured ones.
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

    /// File extensions that are units, without the dot. Empty is invalid:
    /// a corpus that matches nothing is a declaration that does nothing.
    public var include: [String]
    /// Directory names never walked. Build products and vendored dependencies
    /// are not how the user writes, and a crawl through them is expensive and
    /// misleading at once.
    public var exclude: [String]
    /// What this notation is called, in one word, for the style profile's
    /// scope. `swift`, `markdown`, `prose`.
    public var notation: String
    public var relations: PluginCorpusRelations
    public var style: [PluginCorpusStyleRule]
    public var budgets: PluginCorpusBudgets

    public init(
        include: [String],
        exclude: [String] = [],
        notation: String,
        relations: PluginCorpusRelations = .init(),
        style: [PluginCorpusStyleRule] = [],
        budgets: PluginCorpusBudgets = .init()
    ) {
        self.include = include
        self.exclude = exclude
        self.notation = notation
        self.relations = relations
        self.style = style
        self.budgets = budgets
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case include
        case exclude
        case notation
        case relations
        case style
        case budgets
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        include = try values.decode([String].self, forKey: .include)
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
        notation = try values.decode(String.self, forKey: .notation)
        relations = try values.decodeIfPresent(
            PluginCorpusRelations.self, forKey: .relations) ?? .init()
        style = try values.decodeIfPresent([PluginCorpusStyleRule].self, forKey: .style) ?? []
        budgets = try values.decodeIfPresent(
            PluginCorpusBudgets.self, forKey: .budgets) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(include, forKey: .include)
        if !exclude.isEmpty { try container.encode(exclude, forKey: .exclude) }
        try container.encode(notation, forKey: .notation)
        if relations != PluginCorpusRelations() {
            try container.encode(relations, forKey: .relations)
        }
        if !style.isEmpty { try container.encode(style, forKey: .style) }
        if budgets != PluginCorpusBudgets() { try container.encode(budgets, forKey: .budgets) }
    }
}
