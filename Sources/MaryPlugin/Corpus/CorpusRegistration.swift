//
//  CorpusRegistration.swift
//  MaryPlugin
//
//  WHAT: Which applications have a corpus, from package declarations.
//  IN:   PluginCorpusSchema
//  OUT:  CorpusObserver (passive) / ProjectCorpusAdapter (answers the model)
//  PIN:  One roster, two consumers. `structure` distinguishes a project outline
//        from a body of files to learn from.
//

import Foundation
import MaryAmbient
import MaryFoundation

/// One application's corpus declaration, bound to that application.
public struct CorpusRegistration: Sendable, Equatable, SurfaceClaim {
    public let applicationID: String
    public let bundleIdentifiers: [String]
    public let displayName: String
    public let schema: PluginCorpusSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        displayName: String,
        schema: PluginCorpusSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.displayName = displayName
        self.schema = schema
    }

    /// Disk shape when this is a project. Nil for a notation-only corpus.
    public var structure: PluginCorpusStructureSchema? { schema.structure }

    /// Prefix-matched family membership. Launching still needs an exact id.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.declaredStem(
            bundleID: bundleID,
            identifiers: bundleIdentifiers)
    }
}

/// Installed corpora, swapped whole when packages change.
public final class CorpusSupport: @unchecked Sendable {

    public static let shared = CorpusSupport()

    private let roster = SurfaceRoster<CorpusRegistration>()

    public init() {}

    /// Frozen swap. A reader mid-poll must see one consistent roster.
    public func reconcile(_ registrations: [CorpusRegistration]) {
        roster.reconcile(registrations)
    }

    public var all: [CorpusRegistration] { roster.all() }

    public func registration(bundleID: String) -> CorpusRegistration? {
        roster.registration(bundleID: bundleID)
    }

    /// Corpora with a `structure` — projects a lane can read an outline from.
    public var withStructure: [CorpusRegistration] {
        all.filter { $0.structure != nil }
    }

    public func registration(applicationID: String) -> CorpusRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public static func pid(of registration: CorpusRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }
}
