//
//  PluginProseSurfaceSchema.swift
//  MaryFoundation
//
//  WHERE AN APPLICATION KEEPS ITS EDITABLE TEXT — declared, not coded.
//
//  This is the block that lets a text editor join Mary without a single Swift
//  file naming it. Mary compiles in ONE generic prose adapter that knows how
//  to walk an Accessibility tree, find a text area, read it, locate a passage
//  inside it, and replace that passage. What it does NOT know is which role to
//  descend to in this application, how this application names a document, or
//  which chord makes a new one. That is what a package supplies here.
//
//  WHY THIS EXISTS AT ALL — the constraint it answers. A managed-UI operation
//  presses keys and reports whether the press landed; it cannot hand a value
//  back (PluginSchema's header, consequence 1). So "read my document" can
//  never be a recipe. The alternative Mary rejects is an application-specific
//  reader compiled in, which is a native plugin wearing a package's name. The
//  alternative Mary takes is this: the reader is generic and the COORDINATES
//  are declared.
//
//  THE FAMILY, NOT THE APPLICATION. Everything below is true of a whole class
//  of software — "an AppKit editor that exposes its text through
//  Accessibility" — and nothing below is true of only one member of it. If a
//  field could only ever be filled in one way by one application, it does not
//  belong in this schema; it belongs in that application's own package as an
//  operation, or nowhere.
//
//  WHAT IS DELIBERATELY ABSENT. No file paths to read, no polling command, no
//  script, no selector language, no per-application quirk flags. A package
//  says WHERE text lives and WHAT a document is called; every judgement about
//  when to look, how much to read, and whether a write is safe stays with
//  Mary.
//

import Foundation

/// How this application's paragraphs should be segmented into passages.
///
/// A closed vocabulary rather than a rule set: segmentation is Mary's
/// judgement, and a package that could describe its own heading heuristics
/// could make "the second paragraph" mean something the user never sees.
public enum PluginProseGrammar: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ordinary prose: blank-line paragraphs, short standalone lines read as
    /// headings when they contrast with their neighbours.
    case prose
    /// Every non-empty line is its own unit and nothing is a heading. For
    /// editors used as scratchpads and list-keepers.
    case lines
}

/// How a document in this application gets a stable name across polls.
///
/// The problem being solved: a window title changes when the document is
/// edited (an edited-dot, a "— Edited" suffix) and two untitled documents
/// share one title, so a title is not an identity. Both cases below start from
/// something the window itself reports and fall back only to a coordinate that
/// is at least unique within the session.
public enum PluginProseDocumentKey: String, Codable, Hashable, Sendable, CaseIterable {
    /// The window's `AXDocument` file URL when it has one, else the window's
    /// own identifier. Correct for document-based applications, which is most
    /// of them: an unsaved document still has a distinct autosave URL.
    case documentPathThenWindow
    /// The window identifier alone. For applications whose windows are not
    /// documents and never carry a URL.
    case windowOnly
}

/// One key chord this application answers to, named by what it accomplishes
/// rather than by which keys it presses.
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

/// What this application calls one of its documents, in the user's language.
///
/// Mary speaks these words back: "Essay — about 400 words, with two other
/// notes open I haven't read." Getting the noun from the package is why that
/// sentence can be generic without sounding generic.
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

/// How often Mary should re-look at this application while it is in use.
///
/// Bounded by the validator, not by the package: a cadence is a cost paid by
/// the whole machine, and a package that could ask for a 50 ms poll could make
/// every other application's perception late.
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

/// How much text Mary may take from this application at once.
///
/// Three different questions, so three numbers: what a whole-document read
/// returns, what a located region returns, and how much of the front document
/// rides along in ambient context every turn whether or not anyone asked.
/// The last is the one that matters most — it is charged to the prompt budget
/// on every single turn.
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

    /// The letter Mary mints spoken handles from — `[W1]`, `[W2]` — so a
    /// person can say "the second one" and mean something exact. One letter,
    /// upper case, and unique across installed packages.
    public var handlePrefix: String

    /// Accessibility roles to descend to, in preference order. The largest
    /// element of the first role that matches wins, because an editor window
    /// commonly holds several text areas and only one of them is the document.
    public var editorRoles: [PluginAccessibilityRole]

    /// How paragraphs segment into addressable passages.
    public var grammar: PluginProseGrammar

    /// How a document earns a stable name.
    public var documentKey: PluginProseDocumentKey

    /// What the user calls one of these.
    public var documentNoun: PluginProseDocumentNoun

    /// Chords this application answers to, keyed by what they accomplish.
    /// Only `newDocument` is consulted today; unknown keys are refused rather
    /// than ignored, so a package cannot smuggle an unrecognized verb past a
    /// build that would not honour it.
    public var chords: [PluginProseChordName: PluginProseChord]

    /// How often to look while this application is in use.
    public var watch: PluginProseWatchSchema

    /// How much text may be taken at once.
    public var budgets: PluginProseBudgetSchema

    /// The named chords a prose surface may declare.
    ///
    /// `CodingKeyRepresentable` IS LOAD-BEARING, and its absence was a real
    /// defect found by writing the first package that declares a chord.
    /// Swift encodes a `Dictionary` whose key is merely `RawRepresentable` as
    /// a FLAT ALTERNATING ARRAY — `["newDocument", {…}]` — which is not a
    /// shape any author would write by hand, is not what the field's own
    /// documentation implies, and fails to decode the object they do write.
    /// The conformance is what makes `"chords": {"newDocument": {…}}` the
    /// format, which is the only format worth having.
    ///
    /// It survived until now because nothing had ever round-tripped a
    /// NON-EMPTY chords map: an empty dictionary encodes identically either
    /// way, so every test of the schema passed while the one shape a package
    /// needs was unreachable.
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

    /// Hand-written so an omitted section stays omitted in the canonical bytes
    /// the package digest is taken over.
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
