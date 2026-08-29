//
//  PluginCodeSurfaceSchema.swift
//  MaryFoundation
//
//  WHERE AN APPLICATION KEEPS ITS LIVE CODE BUFFER — declared, not coded.
//
//  `PluginProseSurfaceSchema`'s sibling for the other kind of editable text
//  Mary can be shown: a source file open in a code editor. Mary compiles in
//  ONE generic code-surface reader that knows how to walk an Accessibility
//  tree, find a text area, read the whole live buffer out of it, and read the
//  live selection. What it does NOT know is which role to descend to in this
//  application or how this application names a document — the same two
//  questions `PluginProseSurfaceSchema` answers for prose, answered here for
//  code.
//
//  THE PROSE SURFACE'S SIBLING, DELIBERATELY THINNER, and read-only rather
//  than read-write. `coding.mary`'s own guardrail is "never type prose into a
//  code surface", and it holds for synthesized edits too — Mary has no
//  code-writing lane, so this schema declares no write half at all. Everything
//  `PluginProseSurfaceSchema` carries FOR WRITING drops out here:
//
//    - `grammar` — there is no passage machinery segmenting a code buffer
//      into addressable units; nothing here ever locates or replaces a span.
//    - `chords[.newDocument]` — a creation ceremony belongs to the coding
//      discipline's own operations, not this declaration. Xcode already
//      answers to its own chords (build, run, test, save) in `coding.mary`.
//    - `watch` — unconsumed by the prose surface's own runtime today (see
//      `PluginProseSurfaceSchema`'s header), so it is not worth declaring a
//      second field nothing yet reads.
//    - `documentNoun` — with no multi-document listing skill on this side of
//      the family (there is no `list_buffers`), there is no sentence that
//      needs a spoken word for "one of these."
//
//  WHAT SURVIVES is exactly the shape the generic reader needs: where the
//  text lives (`editorRoles`), how a document earns a stable name across
//  polls (`documentKey`, reused from the prose family — a window title is not
//  identity is the same problem for a source file as for a note), how much
//  may be taken at once (`budgets`, same reuse), and the letter a spoken
//  handle would mint under (`handlePrefix`) — reserved rather than exercised
//  by today's adapter, kept for the same reason
//  `PluginCorpusStructureSchema.handlePrefix` is: cross-package collision
//  safety survives even a field this cut's adapter does not yet mint from.
//
//  THE FAMILY, NOT THE APPLICATION. Everything below is true of a whole class
//  of software — "a code editor that exposes its buffer through
//  Accessibility" — and nothing below is true of only one member of it.
//

import Foundation

/// The declared coordinates of one application's live code buffer.
public struct PluginCodeSurfaceSchema: Codable, Hashable, Sendable {

    /// The letter Mary mints spoken handles from, in the same closed
    /// namespace `PluginProseSurfaceSchema.handlePrefix` mints under —
    /// `PluginGraphValidator` checks both families together so one letter
    /// never means two different windows. One letter, upper case, unique
    /// across installed packages.
    public var handlePrefix: String

    /// Accessibility roles to descend to, in preference order. The largest
    /// element of the first role that matches wins — an editor window
    /// commonly holds several text-shaped elements (a jump-bar search field,
    /// a console) and only one of them is the source buffer. Measured
    /// against Xcode: the real source editor is a completely standard
    /// `AXTextArea`, and a stray click can land on the jump bar's
    /// `AXTextField` instead — disambiguated by exact role name, never by
    /// "text-shaped" alone.
    public var editorRoles: [PluginAccessibilityRole]

    /// How a document in this application earns a stable name across polls.
    public var documentKey: PluginProseDocumentKey

    /// How much text may be taken at once.
    public var budgets: PluginProseBudgetSchema

    /// Same identity the corpus observer uses, so a code editor that does
    /// not declare a corpus can still say how its window names the file.
    public var workspaceIdentity: PluginWorkspaceIdentitySchema

    public init(
        handlePrefix: String,
        editorRoles: [PluginAccessibilityRole] = [.textArea],
        documentKey: PluginProseDocumentKey = .documentPathThenWindow,
        budgets: PluginProseBudgetSchema = .init(),
        workspaceIdentity: PluginWorkspaceIdentitySchema = .default
    ) {
        self.handlePrefix = handlePrefix
        self.editorRoles = editorRoles
        self.documentKey = documentKey
        self.budgets = budgets
        self.workspaceIdentity = workspaceIdentity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case handlePrefix
        case editorRoles
        case documentKey
        case budgets
        case workspaceIdentity
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handlePrefix = try values.decode(String.self, forKey: .handlePrefix)
        editorRoles = try values.decodeIfPresent(
            [PluginAccessibilityRole].self, forKey: .editorRoles) ?? [.textArea]
        documentKey = try values.decodeIfPresent(
            PluginProseDocumentKey.self, forKey: .documentKey) ?? .documentPathThenWindow
        budgets = try values.decodeIfPresent(
            PluginProseBudgetSchema.self, forKey: .budgets) ?? .init()
        workspaceIdentity = try values.decodeIfPresent(
            PluginWorkspaceIdentitySchema.self, forKey: .workspaceIdentity) ?? .default
    }

    /// Hand-written so the field order stays stable across the codec, for
    /// the same reason `PluginProseSurfaceSchema` writes its own: the package
    /// digest is taken over these exact bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handlePrefix, forKey: .handlePrefix)
        try container.encode(editorRoles, forKey: .editorRoles)
        try container.encode(documentKey, forKey: .documentKey)
        try container.encode(budgets, forKey: .budgets)
        if workspaceIdentity != .default {
            try container.encode(workspaceIdentity, forKey: .workspaceIdentity)
        }
    }
}
