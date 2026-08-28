//
//  CorpusRegistration.swift
//  MaryPlugin
//
//  WHICH APPLICATIONS HAVE A CORPUS, resolved from what their packages
//  declared. The prose lane's registry, in the same shape, for the same
//  reason: one generic producer needs to know whose coordinates it is using.
//

import AppKit
import Foundation
import MaryFoundation
import os

/// One application's corpus declaration, bound to the application it came
/// from.
public struct CorpusRegistration: Sendable, Equatable {
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
}

/// The installed corpora, swapped whole when packages change.
public final class CorpusSupport: @unchecked Sendable {

    public static let shared = CorpusSupport()

    private let box = OSAllocatedUnfairLock<[CorpusRegistration]>(initialState: [])

    public init() {}

    /// FROZEN SWAP, not a mutation. Importing or editing a package changes the
    /// whole answer, and a reader mid-poll must see one consistent roster
    /// rather than half of each.
    public func reconcile(_ registrations: [CorpusRegistration]) {
        box.withLock { $0 = registrations }
    }

    public var all: [CorpusRegistration] { box.withLock { $0 } }

    public func registration(bundleID: String) -> CorpusRegistration? {
        box.withLock { registrations in
            registrations.first { $0.bundleIdentifiers.contains(bundleID) }
        }
    }

    public func registration(applicationID: String) -> CorpusRegistration? {
        box.withLock { registrations in
            registrations.first { $0.applicationID == applicationID }
        }
    }

    public static func pid(of registration: CorpusRegistration) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            guard let bundleID = application.bundleIdentifier else { return false }
            return registration.bundleIdentifiers.contains(bundleID)
        }?.processIdentifier
    }
}
