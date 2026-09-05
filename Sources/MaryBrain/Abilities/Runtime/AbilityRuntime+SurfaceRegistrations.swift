//
//  AbilityRuntime+SurfaceRegistrations.swift
//  MaryBrain
//
//  WHAT: The declared surfaces in this activation — players, prose, code, browsers.
//  IN:   the activated snapshot's package records
//  OUT:  MediaSurfaceSupport / ProseSurfaceSupport / CodeSurfaceSupport
//  PIN:  A TAUGHT APPLICATION IS NOT A PLAYER UNTIL ITS DECLARATION IS
//        RECONCILED. The adapters are generic by construction — `media-surface`
//        knows what "Next" is called only because a package said so — so a host
//        that loads the graph and dispatches without reconciling these gets
//        "that isn't running" for an app that plainly is.
//        IN MARYBRAIN BECAUSE SAND CANNOT REACH MARYRUNTIME. These were
//        `package static` on MaryRuntime, which the app and the probes link and
//        Sand's bench deliberately does not — it wants the ability graph and
//        the hands, not Granite, Totem or a model. They read nothing but the
//        snapshot's own records, so they belong beside it. Corpus stays in
//        MaryRuntime: it consults inheritance and habits, and it starts crawls.
//        AWARENESS IS SPLIT, and the split is the crawl. Following a DOCUMENT
//        means walking a project, which is MaryRuntime's to install; following
//        a PAGE walks nothing at all — it reads a browser's chrome through
//        Accessibility and reports the roster a skill already produced. The
//        page half therefore belongs here, where a bench can have it too.
//

import Foundation
import MaryFoundation
import MaryPlugin

public extension AbilityRuntime.Snapshot {

    /// Applications that asked to be followed AND show pages — the awareness
    /// registrations that need no project and start no crawl.
    ///
    /// PIN: NEVER A CORPUS. A page is not a project; see
    /// `AwarenessRegistration.corpus`. The document half of this derivation
    /// lives in `MaryRuntime.awarenessRegistrations`, which also consults
    /// inheritance — the thing that could hand a walk grammar to a browser if
    /// nothing forbade it.
    func awarenessPageRegistrations() -> [AwarenessRegistration] {
        let activated = Dictionary(
            records
                .filter(\.validation.isValid)
                .map { ($0.package.package.id, $0.package) },
            uniquingKeysWith: { first, _ in first })
        guard activated.values.contains(where: { $0.ability.id == .awareness }) else {
            return []
        }
        return records.compactMap { record -> AwarenessRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  plugin.webSurface != nil,
                  !plugin.application.bundleIdentifiers.isEmpty
            else { return nil }
            let required = record.package.dependencies.filter { !$0.optional }
            guard required.allSatisfy({ activated[$0.packageID] != nil }) else {
                return nil
            }
            guard record.package.dependencies.contains(where: {
                activated[$0.packageID]?.ability.id == .awareness
            }) else { return nil }
            return AwarenessRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                corpus: nil,
                hasCodeSurface: plugin.codeSurface != nil,
                hasProseSurface: plugin.proseSurface != nil,
                hasWebSurface: true)
        }
    }

    /// Declared transports — every package that carries a `mediaSurface`.
    func mediaSurfaceRegistrations() -> [MediaSurfaceRegistration] {
        records.compactMap { record -> MediaSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.mediaSurface
            else { return nil }
            return MediaSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                schema: surface)
        }
    }

    /// Declared browsers — every package that carries a `webSurface`.
    ///
    /// The block describes the browser's CHROME only. What is inside the page needs no
    /// declaration, because it is read from pixels.
    func webSurfaceRegistrations() -> [WebSurfaceRegistration] {
        records.compactMap { record -> WebSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.webSurface
            else { return nil }
            return WebSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                schema: surface)
        }
    }

    /// Declared prose surfaces. Twin of the media builder.
    func proseSurfaceRegistrations() -> [ProseSurfaceRegistration] {
        records.compactMap { record -> ProseSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.proseSurface
            else { return nil }
            return ProseSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: surface)
        }
    }

    /// Read-only sibling of the prose builder.
    func codeSurfaceRegistrations() -> [CodeSurfaceRegistration] {
        records.compactMap { record -> CodeSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.codeSurface
            else { return nil }
            return CodeSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                schema: surface)
        }
    }
}
