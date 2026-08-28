//
//  CorpusRegistration.swift
//  MaryPlugin
//
//  WHICH APPLICATIONS HAVE A CORPUS, resolved from what their packages
//  declared. The prose lane's registry, in the same shape, for the same
//  reason: one generic producer needs to know whose coordinates it is using.
//
//  ONE ROSTER, TWO CONSUMERS, and the distinction is worth stating because
//  the second one arrived later and briefly grew a roster of its own:
//
//    · `CorpusObserver` (a MaryObserver) watches a corpus PASSIVELY — it
//      crawls the files, counts style evidence, and feeds the unit index. It
//      answers nothing and is never called by the model.
//    · `DocumentCorpusAdapter` (a MaryAdapter) answers the model — an
//      outline, a document's text, a search — and changes a project's shape
//      through its application's own menus.
//
//  Those are different PROTOCOLS answering different questions, and they
//  legitimately differ. What they must not differ about is WHICH
//  APPLICATIONS have a corpus, which is one fact declared in one block. A
//  second registration type and a second registry meant two answers to that
//  question, kept in step by hand.
//
//  The `structure` sub-block is what tells them apart at use: a corpus
//  without one is a body of files to learn from (xcode.mary), and only a
//  corpus WITH one is a project with an outline to read.
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

    /// How this project is shaped on disk, when it is a project rather than a
    /// folder of files. Nil for a notation-only corpus.
    public var structure: PluginCorpusStructureSchema? { schema.structure }

    /// PREFIX-MATCHED, and the case it exists for is a real one: Scrivener's
    /// bundle id carries its major version — `…scrivener3` today,
    /// `…scrivener4` next year — and the Setapp build adds its own suffix, so
    /// a package naming the family should not stop working at the next
    /// release. Exact matching also silently excludes `com.apple.dt.Xcode-beta`
    /// from a declaration that names Xcode.
    ///
    /// Membership only. Nothing here launches anything, and launching needs
    /// an exact id.
    public func owns(bundleID: String) -> Bool {
        bundleIdentifiers.contains { bundleID.lowercased().hasPrefix($0.lowercased()) }
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
            registrations.first { $0.owns(bundleID: bundleID) }
        }
    }

    /// The corpora that are PROJECTS — the ones a document lane can read an
    /// outline out of, as opposed to a body of files to learn style from.
    public var withStructure: [CorpusRegistration] {
        all.filter { $0.structure != nil }
    }

    public func registration(applicationID: String) -> CorpusRegistration? {
        box.withLock { registrations in
            registrations.first { $0.applicationID == applicationID }
        }
    }

    public static func pid(of registration: CorpusRegistration) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            guard let bundleID = application.bundleIdentifier else { return false }
            return registration.owns(bundleID: bundleID)
        }?.processIdentifier
    }
}
