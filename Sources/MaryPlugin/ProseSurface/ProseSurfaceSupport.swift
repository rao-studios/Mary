//
//  ProseSurfaceSupport.swift
//  MaryPlugin
//
//  THE REGISTRY OF DECLARED PROSE SURFACES — and the one place that teaches
//  the passage verbs where a document is.
//
//  Packages arrive and leave (an import, an uninstall, an edit that
//  hot-reloads), so this holds whatever is currently declared and answers
//  three questions about it: which application owns a place, what its prose
//  coordinates are, and how to read and write its documents.
//
//  IT INSTALLS THE BACKING RESOLVER, which is the whole reason it exists as a
//  registry rather than a list. Bonnie kept a compiled table mapping each
//  writing world to its reader and writer, installed at boot by the typer;
//  an application taught by package had no row in it and could therefore be
//  read, focused and remembered but never have a passage cut from it — a gap
//  its own documentation recorded and could not close, because the table was
//  keyed on an enum with no case for a taught application. Here the resolver
//  is a lookup in this registry, so an application that declares a prose
//  surface is editable the moment its package loads, and nothing needs a row
//  added anywhere.
//
//  FROZEN-SWAP, not mutate-in-place. Reconciliation replaces the whole map
//  behind a lock and readers take a snapshot; a turn that started reading
//  finishes against the roster it started with rather than half of two.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class ProseSurfaceSupport: @unchecked Sendable {

    public static let shared = ProseSurfaceSupport()

    private let box = OSAllocatedUnfairLock<[String: ProseSurfaceRegistration]>(
        initialState: [:])

    public init() {}

    // MARK: - The roster

    /// Replaces the declared surfaces wholesale.
    ///
    /// Called on every package activation. Reconciliation is a REPLACE rather
    /// than a merge because a package that stops declaring a prose surface
    /// must stop having one — a merge would leave the old declaration
    /// answering for an application that no longer claims it.
    public func reconcile(_ registrations: [ProseSurfaceRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [ProseSurfaceRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    public func registration(applicationID: String) -> ProseSurfaceRegistration? {
        box.withLock { $0[applicationID] }
    }

    public func registration(bundleID: String) -> ProseSurfaceRegistration? {
        box.withLock { map in map.values.first { $0.owns(bundleID: bundleID) } }
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

    /// Points the passage verbs at this registry.
    ///
    /// Idempotent, and safe to call from every composition path — the last
    /// caller wins and they all install the same closure.
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
            // EVERY PROSE SURFACE CAN ADDRESS A SECOND DOCUMENT. Bonnie left
            // this nil for all but one application, because reaching a
            // background window meant that application's scripting layer;
            // an accessibility walk enumerates every window the same way, so
            // the capability is the family's rather than one member's.
            bodyForDocument: { key in Self.snapshot(registration, documentKey: key) },
            writer: writer)
    }

    // MARK: - Reading

    /// A snapshot of the front document.
    static func snapshot(front registration: ProseSurfaceRegistration) -> BodySnapshot? {
        guard let pid = pid(of: registration),
              let surface = ProseSurfaceAX.frontSurface(pid: pid, registration: registration)
        else { return nil }
        return snapshot(of: surface, registration: registration)
    }

    /// A snapshot of ONE NAMED document — nil when this application does not
    /// recognize the key.
    ///
    /// Nil rather than the front document, deliberately. Falling back is how
    /// "revise the todo note" edits whatever happens to be in front, which is
    /// the exact failure a multi-window application exists to avoid.
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
        SurfacePollTarget.pid(
            of: registration, running: SurfacePollTarget.runningProcesses())
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
