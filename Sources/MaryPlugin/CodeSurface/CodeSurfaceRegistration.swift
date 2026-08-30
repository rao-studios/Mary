//
//  CodeSurfaceRegistration.swift
//  MaryPlugin
//
//  ONE APPLICATION'S DECLARED CODE COORDINATES, resolved for use.
//
//  `ProseSurfaceRegistration`'s sibling: a package writes a `codeSurface`
//  block, the compiler that admits the package pairs it with the
//  application's identity, and this is what the runtime uses — identity
//  attached, roles resolved to the AX strings the walk compares against.
//  Kept apart from `PluginCodeSurfaceSchema` for the same reason
//  `ProseSurfaceRegistration` is kept apart from its schema: a schema change
//  cannot silently alter runtime behaviour, and the mapping between them is
//  one function with a test.
//

import Foundation
import MaryAmbient
import MaryFoundation

public struct CodeSurfaceRegistration: Sendable, Equatable, SurfaceClaim, DeclaredTextSurface {

    /// The package's logical id for the application — the same id its place
    /// is spelled with (`applications:xcode`).
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginCodeSurfaceSchema

    /// The process FAMILY, when the package declared one. Same field, same
    /// reason as `ApplicationRegistration.bundleIdentifierPrefix`:
    /// `bundleIdentifiers` is exact and stays the authority for launching,
    /// but membership — "is the running editor one of this package's?" — is
    /// a prefix question for any vendor who ships `…app3` and then `…app4`
    /// (or `com.apple.dt.Xcode-beta` beside `com.apple.dt.Xcode`). Absent
    /// means the exact identifiers are the whole answer.
    public let bundleIdentifierPrefix: String?

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        bundleIdentifierPrefix: String? = nil,
        displayName: String,
        schema: PluginCodeSurfaceSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
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

    /// The letter this application mints spoken handles from — `[C1]`.
    public var handlePrefix: String { schema.handlePrefix }

    public var budgets: PluginProseBudgetSchema { schema.budgets }

    public var preferFocusedElement: Bool { schema.preferFocusedElement }

    public var editorWalkBudget: AXTreeWalker.Budget { .standard }

    /// Whether this registration claims the given process.
    ///
    /// EXACT FIRST, THEN THE FAMILY — the same two-tier question
    /// `ApplicationRegistration.owns(bundleID:)` answers for ambient routing
    /// and `TypingSurface.isRunning` answers for the taught-writing-surface
    /// rung (`[Corpus P]`), asked here through the identical boundary
    /// predicate, `ApplicationRegistration.isInFamily`. This registration
    /// used to compare only the exact declared id — the same latent shape
    /// `[Corpus P]` fixed elsewhere and noted, but deliberately left
    /// unchanged, here (no currently-taught code application declares a
    /// versioned bundle id, so nothing live broke) — closed now rather than
    /// waiting for a fourth incident.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }
}
