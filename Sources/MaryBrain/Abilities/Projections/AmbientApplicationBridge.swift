//
//  AmbientApplicationBridge.swift
//  MaryBrain
//
//  THE ROSTER OF APPLICATIONS, HANDED DOWN. The ambient layer asks "which
//  applications exist on this machine"; this is the half that knows, because
//  the answer is the compiled plugin roster joined to whatever Dynamic package
//  graph the library last admitted, and MaryAmbient may name neither.
//
//  WHY EVERY PROFILE BECOMES A REGISTRATION, including the twenty-two that
//  already have worlds. A registry that held only the applications WITHOUT an
//  `AmbientWorld` would be a second, partial inventory, and the first question
//  anyone asked it — "is this bundle id one of ours?" — would need both lists
//  and get the join wrong eventually. One roster, `legacyWorld` non-nil for the
//  ones that are also worlds, is the shape that cannot drift.
//

import Foundation

public enum AmbientApplicationBridge {

    /// Builds the registry from the merged Native + Dynamic profile list — the
    /// same list `MaryRuntime` publishes and re-publishes on every
    /// `AbilityLibrary` activation.
    public static func roster(
        profiles: [ApplicationProfile]
    ) -> AmbientApplicationRoster {
        AmbientApplicationRoster(profiles.map(registration(for:)))
    }

    /// Points MaryAmbient at the roster. Called at configuration and again
    /// whenever a package is imported, edited or removed, because that changes
    /// which applications exist for the next turn.
    public static func install(profiles: [ApplicationProfile]) {
        let built = roster(profiles: profiles)
        AmbientApplicationIndexProvider.install { built }
    }

    /// One profile's registration.
    ///
    /// THE CLASS IS THE ONLY REAL DECISION HERE. A profile whose id is a plugin
    /// owner IS a built-in world, so it inherits that world's class and projects
    /// onto it — nothing about those twenty-two changes, which is what keeps
    /// this addition invisible to every existing behaviour.
    ///
    /// Everything else is an application Mary was TAUGHT, and its class comes
    /// from the package's optional opt-in to Mary's generic Accessibility
    /// perception. Dynamic packages cannot provide document readers or timers.
    ///
    /// A package that declared nothing is `.dataSource`: queried on demand,
    /// with nothing to look at. That is the honest reading — no watcher, so no
    /// eyes — and it is deliberately NOT `.perceptionOnly`, which means the
    /// opposite (a watcher, but no Skills). A Dynamic package with no
    /// perception contract is all Skills and no watcher.
    static func registration(for profile: ApplicationProfile) -> ApplicationRegistration {
        let builtIn = AmbientWorld.from(pluginOwner: profile.id)
        return ApplicationRegistration(
            id: profile.id,
            profile: profile,
            bundleIdentifiers: profile.applicationIdentifiers,
            bundleIdentifierPrefix: profile.applicationBundlePrefix,
            worldClass: builtIn?.worldClass
                ?? profile.perception?.worldClass
                ?? .dataSource,
            displayName: builtIn?.displayName ?? profile.title,
            perception: profile.perception,
            legacyWorld: builtIn)
    }
}
