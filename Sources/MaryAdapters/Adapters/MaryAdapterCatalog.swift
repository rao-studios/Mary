//
//  MaryAdapterCatalog.swift
//  MaryAdapters
//
//  THE ADAPTERS MARY SHIPS — the whole roster, in one file.
//
//  Bonnie's equivalent was 318 lines listing twenty-two application
//  integrations behind eight support lanes, most of them gated by a Settings
//  toggle keyed on an application's name. That file was where "which
//  applications does the assistant know" was answered, and it had to grow by a
//  case every time the answer changed.
//
//  Here the answer is: none. Every adapter below is generic — it serves
//  whichever application a Plugin points it at, and adding an application adds
//  no line to this file. What a catalog is FOR, in Mary, is much smaller: hand
//  the runtime the compiled providers so it can collect their manifests and
//  activate their observers.
//
//  TWO ROSTERS, because they answer to different lifecycles. ADAPTERS carry
//  Skill bindings and are dispatched against; OBSERVERS carry senses, are
//  activated and deactivated, and contribute to a prompt. A type can be both,
//  and several are.
//

import Foundation

public enum MaryAdapterCatalog {

    /// Every compiled provider with Skill bindings.
    ///
    /// Generic every one: the typer types wherever a cursor is, the prose
    /// surface reads and writes whatever declares one, window management
    /// raises whatever has windows. Adding an application adds no entry.
    public static func adapters() -> [any MaryAdapter] {
        [ApplicationsAdapter(), ProseSurfaceAdapter(), TyperPlugin(), WindowManagementPlugin()]
    }

    /// Every compiled provider with senses.
    ///
    /// UNGATED, DELIBERATELY, and the reason is worth keeping: these are not
    /// applications' representations but faculties that serve every
    /// application at once. A per-application setting must never decide
    /// whether Mary can see the screen — a toggle for one application
    /// silently blinding her in a different one is the kind of coupling that
    /// takes a week to diagnose.
    public static func observers() -> [any MaryObserver] {
        AmbientSurfaceSupport.all + ApplicationsSupport.shared.all
    }

    /// The value-only adapter handshake for one runtime configuration.
    ///
    /// Callers pass the exact roster they activate, so a provider that is not
    /// installed disappears from execution and from schema readiness together
    /// — a manifest claiming a Skill nothing will run is how a package comes
    /// to look installed and do nothing.
    public static func adapterManifests(
        adapters: [any MaryAdapter],
        observers: [any MaryObserver] = []
    ) -> [InstalledAdapterManifest] {
        adapters.map(\.adapterManifest) + observers.compactMap(\.adapterManifest)
    }
}
