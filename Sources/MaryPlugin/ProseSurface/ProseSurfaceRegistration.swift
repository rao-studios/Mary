//
//  ProseSurfaceRegistration.swift
//  MaryPlugin
//
//  WHAT: One app's declared prose coordinates, identity attached.
//  IN:   PluginProseSurfaceSchema  OUT: ProseSurfaceSupport

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
