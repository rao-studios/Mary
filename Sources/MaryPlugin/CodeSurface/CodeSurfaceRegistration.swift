//
//  CodeSurfaceRegistration.swift
//  MaryPlugin
//
//  WHAT: One app's declared code coordinates, identity attached.
//  IN:   PluginCodeSurfaceSchema  OUT: CodeSurfaceSupport

import Foundation
import MaryAmbient
import MaryComputerUse
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

    /// The process FAMILY, when the package declared one. Same field, same reason as
    /// `ApplicationRegistration.bundleIdentifierPrefix`: `bundleIdentifiers` is exact and
    /// stays the authority for launching, but membership.
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

    /// Whether this registration claims the given process. EXACT FIRST, THEN THE FAMILY —
    /// the same two-tier question `ApplicationRegistration.owns(bundleID:)` answers.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }
}
