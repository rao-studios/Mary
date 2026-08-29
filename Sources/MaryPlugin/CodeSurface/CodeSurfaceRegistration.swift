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
import MaryFoundation

public struct CodeSurfaceRegistration: Sendable, Equatable {

    /// The package's logical id for the application — the same id its place
    /// is spelled with (`applications:xcode`).
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginCodeSurfaceSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        displayName: String,
        schema: PluginCodeSurfaceSchema
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

    /// The letter this application mints spoken handles from — `[C1]`.
    public var handlePrefix: String { schema.handlePrefix }

    public var budgets: PluginProseBudgetSchema { schema.budgets }

    /// Whether this registration claims the given process.
    public func owns(bundleID: String) -> Bool {
        bundleIdentifiers.contains { bundleID.caseInsensitiveCompare($0) == .orderedSame }
    }
}
