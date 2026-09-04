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
//        snapshot's own records, so they belong beside it. Corpus and awareness
//        stay in MaryRuntime: they consult inheritance and habits, and they
//        start crawls.
//

import Foundation
import MaryFoundation
import MaryPlugin

public extension AbilityRuntime.Snapshot {

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
