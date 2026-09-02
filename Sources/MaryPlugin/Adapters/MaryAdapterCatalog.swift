//
//  MaryAdapterCatalog.swift
//  MaryPlugin
//
//  WHAT: Compiled providers Mary ships — adapters and observers.
//  IN:   composition root
//  OUT:  adapters() / observers() / adapterManifests
//  PIN:  Generic faculties; adding an application adds no line here.
//        Two rosters: Skill bindings vs senses (a type can be both).
//

import Foundation

public enum MaryAdapterCatalog {

    /// Compiled providers with Skill bindings. Adding an application adds none.
    public static func adapters() -> [any MaryAdapter] {
        [ApplicationsAdapter(), AwarenessAdapter(), CodeSurfaceAdapter(), MediaSurfaceAdapter(),
         ProjectCorpusAdapter(), ProjectGitAdapter(), ProjectBuildAdapter(), ProjectQuirksAdapter(),
         EventKitAdapter(), ProseSurfaceAdapter(), TyperPlugin(), WindowManagementPlugin()]
    }

    /// Compiled providers with senses. Ungated: faculties, not app toggles.
    public static func observers() -> [any MaryObserver] {
        AmbientSurfaceSupport.all + ApplicationsSupport.shared.all
            + CodeSurfaceObserverSupport.all + ProseSurfaceObserverSupport.all
            + CorpusObserverSupport.all
            // LAST, so a place's lead and its whole/window claim are still
            // decided by the observer that holds its document — this one only
            // adds bearings to whichever section wins.
            + AwarenessObserverSupport.all
    }

    /// Manifests for the roster the caller actually activates.
    /// PIN: a missing provider must vanish from execution and schema together.
    public static func adapterManifests(
        adapters: [any MaryAdapter],
        observers: [any MaryObserver] = []
    ) -> [InstalledAdapterManifest] {
        adapters.map(\.adapterManifest) + observers.compactMap(\.adapterManifest)
    }
}
