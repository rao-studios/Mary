//
//  ProseSurfaceRegistration.swift
//  MaryPlugin
//
//  ONE APPLICATION'S DECLARED PROSE COORDINATES, resolved for use.
//
//  A package writes a `proseSurface` block; the compiler that admits the
//  package pairs it with the application's identity and hands the result
//  here. Everything the compiled lane needs to read and write that
//  application's text is in this value, and nothing in the lane names the
//  application itself.
//
//  WHY A SEPARATE TYPE FROM THE SCHEMA. `PluginProseSurfaceSchema` is what an
//  author writes and a validator admits: strict decoding, bounded, refusing
//  unknown keys. This is what the runtime uses: identity attached, roles
//  resolved to the AX strings the walk compares against, cadences already
//  clamped. Keeping them apart means a schema change cannot silently alter
//  runtime behaviour, and the mapping between them is one function with a
//  test.
//

import Foundation
import MaryAmbient
import MaryFoundation

public struct ProseSurfaceRegistration: Sendable, Equatable, SurfaceClaim, DeclaredTextSurface {

    /// The package's logical id for the application — the same id its place
    /// is spelled with (`applications:textedit`).
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginProseSurfaceSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        displayName: String,
        schema: PluginProseSurfaceSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.displayName = displayName
        self.schema = schema
    }

    // MARK: - Resolved coordinates

    /// The AX role strings to descend to, in declared preference order.
    ///
    /// The schema names roles from a closed vocabulary (`.textArea`); the walk
    /// compares raw AX strings (`"AXTextArea"`). Converting once here rather
    /// than per node keeps the mapping in one place and off the hot path.
    public var editorRoleNames: [String] {
        schema.editorRoles.map { role in
            "AX" + role.rawValue.prefix(1).uppercased() + role.rawValue.dropFirst()
        }
    }

    public var documentKeyKind: PluginProseDocumentKey { schema.documentKey }

    /// The letter this application mints spoken handles from — `[W1]`.
    public var handlePrefix: String { schema.handlePrefix }

    /// What the user calls one of its documents, for the sentences Mary says.
    public var noun: PluginProseDocumentNoun { schema.documentNoun }

    /// How paragraphs segment into addressable passages.
    public var grammar: PluginProseGrammar { schema.grammar }

    /// The chord that makes a new document, when this application declared
    /// one. Nil is a real answer: an application may be readable and not
    /// creatable, and offering a create it cannot perform is worse.
    public var newDocumentChord: PluginProseChord? {
        schema.chords[.newDocument]
    }

    public var watch: PluginProseWatchSchema { schema.watch }
    public var budgets: PluginProseBudgetSchema { schema.budgets }

    /// Largest declared-role element. Split-pane focus pick is the code
    /// family's; a prose window's document is the big text area.
    public var preferFocusedElement: Bool { false }

    public var editorWalkBudget: AXTreeWalker.Budget {
        AXTreeWalker.Budget(maxDepth: 12, maxNodes: 400)
    }

    /// Whether this registration claims the given process.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: nil)
    }
}
