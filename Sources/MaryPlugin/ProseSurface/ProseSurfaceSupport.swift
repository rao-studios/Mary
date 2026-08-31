//
//  ProseSurfaceSupport.swift
//  MaryPlugin
//
//  WHAT: Registry of declared prose surfaces + backing resolver install.
//  OUT:  PassageBacking lookup
//  PIN:  Frozen-swap, not mutate-in-place.

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

public final class ProseSurfaceSupport: @unchecked Sendable {

    public static let shared = ProseSurfaceSupport()

    private let roster = SurfaceRoster<ProseSurfaceRegistration>()

    public init() {}

    // MARK: - The roster

    public func reconcile(_ registrations: [ProseSurfaceRegistration]) {
        roster.reconcile(registrations)
    }

    public func all() -> [ProseSurfaceRegistration] { roster.all() }

    public func registration(applicationID: String) -> ProseSurfaceRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public func registration(bundleID: String) -> ProseSurfaceRegistration? {
        roster.registration(bundleID: bundleID)
    }

    /// Named editor if running; else the standing pair-session hit; else the
    /// document `ProseSurfaceObserver` already holds a claim on, whoever is
    /// frontmost — see `CodeSurfaceSupport.resolve`, the same reasoning for
    /// the writing family.
    public func resolve(_ named: String?) -> (ProseSurfaceRegistration, pid_t)? {
        roster.resolve(
            named: named,
            standingApplicationID: ProseSurfaceObserver.shared.observedPlace?.application,
            unpreferredFallback: true,
            anyRunningFallback: true)
    }

    /// The registration behind a place, when that place is a declared prose
    /// surface. A lane is never one — Mary's own faculties hold no documents.
    public func registration(place: AmbientPlace) -> ProseSurfaceRegistration? {
        guard case .application(let id) = place else { return nil }
        return registration(applicationID: id)
            // An unregistered application's place carries its BUNDLE id, so a
            // package that claims that bundle still answers for it.
            ?? registration(bundleID: id)
    }

    // MARK: - Installing the seam

    /// Points the passage verbs at this registry. Idempotent, and safe to call from every
    /// composition path — the last caller wins and they all install the same closure.
    public func installBackingResolver() {
        PassageRecipes.installBackingResolver { [weak self] place in
            self?.backing(for: place)
        }
    }

    /// Everything the passage machinery needs for one place, or nil when that
    /// place declares no prose surface.
    public func backing(for place: AmbientPlace) -> PassageBacking? {
        guard let registration = registration(place: place) else { return nil }
        let writer = ProseSurfaceWriter(registration: registration)

        return PassageBacking(
            place: place,
            // The declared grammar decides segmentation, so "the second
            // paragraph" means the same thing to the reader and the writer.
            units: { text in
                ProseStructure.units(in: text, rules: registration.grammar.rules)
            },
            body: { Self.snapshot(front: registration) },
            // AX walk enumerates every window, so a second document is addressable.
            bodyForDocument: { key in Self.snapshot(registration, documentKey: key) },
            writer: writer)
    }

    // MARK: - Reading

    /// A snapshot of the front document.
    static func snapshot(front registration: ProseSurfaceRegistration) -> BodySnapshot? {
        guard let pid = pid(of: registration),
              let surface = CodeSurfaceEditorCache.frontSurface(
                pid: pid, registration: registration)
        else { return nil }
        return snapshot(of: surface, registration: registration)
    }

    /// A snapshot of ONE NAMED document — nil when this application does not recognize the
    /// key. Nil rather than the front document, deliberately.
    static func snapshot(
        _ registration: ProseSurfaceRegistration, documentKey: String
    ) -> BodySnapshot? {
        guard let pid = pid(of: registration) else { return nil }
        let surfaces = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
        guard let surface = surfaces.first(where: { $0.documentKey == documentKey })
        else { return nil }
        return snapshot(of: surface, registration: registration)
    }

    static func snapshot(
        of surface: ProseSurfaceAX.Surface, registration: ProseSurfaceRegistration
    ) -> BodySnapshot? {
        guard let text = ProseSurfaceAX.fullString(of: surface.editor) else { return nil }
        return BodySnapshot(
            text: String(text.prefix(registration.budgets.wholeDocumentCharacters)),
            documentKey: surface.documentKey,
            documentTitle: surface.title,
            capturedAt: Date())
    }

    public static func pid(of registration: ProseSurfaceRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }
}

public extension PluginProseGrammar {
    /// The segmentation rules this grammar names.
    var rules: ProseStructureRules {
        switch self {
        case .prose: return .prose
        case .lines: return .lines
        }
    }
}
