//
//  AwarenessRegistration.swift
//  MaryPlugin
//
//  WHAT: Which applications asked for awareness, from package declarations.
//  IN:   the activated ability graph (MaryRuntime derives these)
//  OUT:  AwarenessAdapter (answers the model) / AwarenessObserver (stands a brief)
//  PIN:  One roster, two consumers — CorpusRegistration's shape and its reason.
//        The corpus rides along because awareness reads the project the
//        expertise declared, and inherits the discipline's grammar when the
//        application declares none of its own.
//

import Foundation
import MaryAmbient
import MaryFoundation

/// One application that declared a dependency on the awareness discipline,
/// bound to that application.
public struct AwarenessRegistration: Sendable, Equatable, SurfaceClaim {

    /// The package's logical id for the application — the id its place is
    /// spelled with (`applications:xcode`).
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// The process FAMILY, when the package declared one. `bundleIdentifiers`
    /// stays the authority for launching; this answers membership.
    public let bundleIdentifierPrefix: String?

    /// What the user calls it.
    public let displayName: String

    /// WHAT KIND OF WORLD THIS IS, and what a walk of it may read.
    ///
    /// PIN: A RULE NOTHING HAS TO REMEMBER. "A page never carries a corpus" was
    /// true, load-bearing, and enforced by hand in BOTH derivations — one
    /// passing `corpus: nil` as a literal, the other guarding with
    /// `isPage ? nil : …`. Two places that must agree eventually disagree, and
    /// the failure would be silent: a discipline donor pointing a crawl at the
    /// web. Here the page case HAS no corpus to give, so the rule holds by
    /// construction and neither derivation can get it wrong.
    public enum Surface: Sendable, Equatable {
        /// Files on disk, and the grammar for walking them. NIL CORPUS IS A REAL
        /// STATE — an application can ask for awareness of a live surface
        /// without having a project to trace through, and the honest answer to
        /// "who calls this" is then that there is nothing to search.
        case document(corpus: PluginCorpusSchema?)

        /// PAGES, AND THE THIRD KIND OF WORLD. A code surface has a buffer and a
        /// prose surface has a document; a browser has neither, and the document
        /// road (`AwarenessSiteResolver.resolve`) bails on exactly that — no
        /// text, no site, no brief. A page is still plainly the work in front of
        /// someone, so it takes its own road (`AwarenessPageSite`). The web is
        /// not a project and nothing here crawls or indexes it.
        case page
    }

    public let surface: Surface

    /// The project grammar awareness walks. Nil for a page, by construction.
    public var corpus: PluginCorpusSchema? {
        guard case .document(let corpus) = surface else { return nil }
        return corpus
    }

    /// Whether this application shows PAGES rather than documents on disk.
    public var hasWebSurface: Bool { surface == .page }

    /// Whether the application declares a live code channel — the buffer,
    /// including unsaved edits — rather than only files on disk.
    public let hasCodeSurface: Bool

    /// The prose twin of `hasCodeSurface`.
    public let hasProseSurface: Bool

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        bundleIdentifierPrefix: String? = nil,
        displayName: String,
        surface: Surface,
        hasCodeSurface: Bool,
        hasProseSurface: Bool
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.displayName = displayName
        self.surface = surface
        self.hasCodeSurface = hasCodeSurface
        self.hasProseSurface = hasProseSurface
    }

    /// Whether this registration claims the given process. Exact first, then
    /// the family — `CodeSurfaceRegistration.owns(bundleID:)`'s own rule.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }
}

/// Installed awareness registrations, swapped whole when packages change.
public final class AwarenessSupport: @unchecked Sendable {

    public static let shared = AwarenessSupport()

    private let roster = SurfaceRoster<AwarenessRegistration>()

    public init() {}

    /// Frozen swap. A reader mid-poll must see one consistent roster.
    public func reconcile(_ registrations: [AwarenessRegistration]) {
        roster.reconcile(registrations)
    }

    public var all: [AwarenessRegistration] { roster.all() }

    public func registration(applicationID: String) -> AwarenessRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public func registration(bundleID: String) -> AwarenessRegistration? {
        roster.registration(bundleID: bundleID)
    }

    /// The registration for a place, when that place is a registered
    /// application. Nil for a lane with no application behind it.
    public func registration(place: AmbientPlace) -> AwarenessRegistration? {
        guard let id = place.application else { return nil }
        return registration(applicationID: id)
    }

    public static func pid(of registration: AwarenessRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }
}
