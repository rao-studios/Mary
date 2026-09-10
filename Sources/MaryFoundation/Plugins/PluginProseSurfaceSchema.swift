//
//  PluginProseSurfaceSchema.swift
//  MaryFoundation
//
//  WHAT: Editable-text coordinates for the generic prose adapter.
//  IN:   PluginSchema.proseSurface.
//  OUT:  PluginValidator+ProseSurface, prose adapter.
//  PIN:  Recipes cannot return values — this is how a package configures a reader.
//

import Foundation

/// Passage segmentation. Closed vocabulary; Mary judges, package does not.
public enum PluginProseGrammar: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ordinary prose: blank-line paragraphs, short standalone lines read as
    /// headings when they contrast with their neighbours.
    case prose
    /// Every non-empty line is its own unit and nothing is a heading. For
    /// editors used as scratchpads and list-keepers.
    case lines
}

/// Stable document name across polls. Title is not identity.
public enum PluginProseDocumentKey: String, Codable, Hashable, Sendable, CaseIterable {
    /// AXDocument URL else window id. Unsaved still has autosave URL.
    case documentPathThenWindow
    /// Window identifier alone. Windows that are not documents and carry no URL.
    case windowOnly
}

/// One chord named by what it does, not which keys it presses.
public struct PluginProseChord: Codable, Hashable, Sendable {
    public var key: PluginKey
    public var modifiers: [PluginKeyModifier]

    public init(key: PluginKey, modifiers: [PluginKeyModifier] = []) {
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(PluginKey.self, forKey: .key)
        modifiers = try values.decodeIfPresent([PluginKeyModifier].self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if !modifiers.isEmpty { try container.encode(modifiers, forKey: .modifiers) }
    }
}

/// Document noun Mary speaks. Package supplies the word.
public struct PluginProseDocumentNoun: Codable, Hashable, Sendable {
    public var singular: String
    public var plural: String

    public init(singular: String, plural: String) {
        self.singular = singular
        self.plural = plural
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case singular
        case plural
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        singular = try values.decode(String.self, forKey: .singular)
        plural = try values.decode(String.self, forKey: .plural)
    }
}

/// Watch cadence. Validator bounds it; package proposes.
public struct PluginProseWatchSchema: Codable, Hashable, Sendable {
    public var activeSeconds: Double
    public var idleSeconds: Double

    public init(activeSeconds: Double = 2.5, idleSeconds: Double = 10) {
        self.activeSeconds = activeSeconds
        self.idleSeconds = idleSeconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case activeSeconds
        case idleSeconds
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeSeconds = try values.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 2.5
        idleSeconds = try values.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? 10
    }
}

/// Read budgets: whole, region, ambient excerpt (charged every turn).
public struct PluginProseBudgetSchema: Codable, Hashable, Sendable {
    public var wholeDocumentCharacters: Int
    public var regionCharacters: Int
    public var ambientExcerptCharacters: Int

    public init(
        wholeDocumentCharacters: Int = 3600,
        regionCharacters: Int = 1800,
        ambientExcerptCharacters: Int = 280
    ) {
        self.wholeDocumentCharacters = wholeDocumentCharacters
        self.regionCharacters = regionCharacters
        self.ambientExcerptCharacters = ambientExcerptCharacters
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case wholeDocumentCharacters
        case regionCharacters
        case ambientExcerptCharacters
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wholeDocumentCharacters =
            try values.decodeIfPresent(Int.self, forKey: .wholeDocumentCharacters) ?? 3600
        regionCharacters =
            try values.decodeIfPresent(Int.self, forKey: .regionCharacters) ?? 1800
        ambientExcerptCharacters =
            try values.decodeIfPresent(Int.self, forKey: .ambientExcerptCharacters) ?? 280
    }
}

/// The declared coordinates of one application's editable text.
public struct PluginProseSurfaceSchema: Codable, Hashable, Sendable {

    /// Spoken-handle letter. Unique across installed packages.
    public var handlePrefix: String

    /// Roles in preference order. Largest match of the first hitting role.
    public var editorRoles: [PluginAccessibilityRole]

    /// How paragraphs segment into addressable passages.
    public var grammar: PluginProseGrammar

    /// How a document earns a stable name.
    public var documentKey: PluginProseDocumentKey

    /// What the user calls one of these.
    public var documentNoun: PluginProseDocumentNoun

    /// Chords by accomplishment. Unknown keys refused, not ignored.
    public var chords: [PluginProseChordName: PluginProseChord]

    /// How often to look while this application is in use.
    public var watch: PluginProseWatchSchema

    /// How much text may be taken at once.
    public var budgets: PluginProseBudgetSchema

    /// Named chords. PIN: CodingKeyRepresentable so JSON is `{"newDocument": {…}}` not an array.
    public enum PluginProseChordName:
        String, Codable, Hashable, Sendable, CaseIterable, CodingKeyRepresentable
    {
        case newDocument

        public init?<T: CodingKey>(codingKey: T) {
            self.init(rawValue: codingKey.stringValue)
        }

        public var codingKey: any CodingKey { ChordKey(stringValue: rawValue) }

        private struct ChordKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }
    }

    public init(
        handlePrefix: String,
        editorRoles: [PluginAccessibilityRole] = [.textArea],
        grammar: PluginProseGrammar = .prose,
        documentKey: PluginProseDocumentKey = .documentPathThenWindow,
        documentNoun: PluginProseDocumentNoun,
        chords: [PluginProseChordName: PluginProseChord] = [:],
        watch: PluginProseWatchSchema = .init(),
        budgets: PluginProseBudgetSchema = .init()
    ) {
        self.handlePrefix = handlePrefix
        self.editorRoles = editorRoles
        self.grammar = grammar
        self.documentKey = documentKey
        self.documentNoun = documentNoun
        self.chords = chords
        self.watch = watch
        self.budgets = budgets
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case handlePrefix
        case editorRoles
        case grammar
        case documentKey
        case documentNoun
        case chords
        case watch
        case budgets
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handlePrefix = try values.decode(String.self, forKey: .handlePrefix)
        editorRoles = try values.decodeIfPresent(
            [PluginAccessibilityRole].self, forKey: .editorRoles) ?? [.textArea]
        grammar = try values.decodeIfPresent(
            PluginProseGrammar.self, forKey: .grammar) ?? .prose
        documentKey = try values.decodeIfPresent(
            PluginProseDocumentKey.self, forKey: .documentKey) ?? .documentPathThenWindow
        documentNoun = try values.decode(PluginProseDocumentNoun.self, forKey: .documentNoun)
        chords = try values.decodeIfPresent(
            [PluginProseChordName: PluginProseChord].self, forKey: .chords) ?? [:]
        watch = try values.decodeIfPresent(
            PluginProseWatchSchema.self, forKey: .watch) ?? .init()
        budgets = try values.decodeIfPresent(
            PluginProseBudgetSchema.self, forKey: .budgets) ?? .init()
    }

    /// Hand-written encode — omitted sections stay omitted for digest.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handlePrefix, forKey: .handlePrefix)
        try container.encode(editorRoles, forKey: .editorRoles)
        try container.encode(grammar, forKey: .grammar)
        try container.encode(documentKey, forKey: .documentKey)
        try container.encode(documentNoun, forKey: .documentNoun)
        if !chords.isEmpty { try container.encode(chords, forKey: .chords) }
        try container.encode(watch, forKey: .watch)
        try container.encode(budgets, forKey: .budgets)
    }
}
