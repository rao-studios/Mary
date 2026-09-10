//
//  AmbientApplicationBridge.swift
//  MaryBrain
//
//  WHAT: Application roster handed down to MaryAmbient.
//  IN:   compiled plugin roster + AbilityLibrary graph
//  OUT:  AmbientApplicationRegistration (legacyAttention non-nil for world apps)
//  PIN:  One roster; never a second partial inventory.
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
    /// PIN: A package that declared nothing is `.dataSource`: queried on demand, with nothing to look at.
    static func registration(for profile: ApplicationProfile) -> ApplicationRegistration {
        let builtIn = AmbientAttention.from(pluginOwner: profile.id)
        return ApplicationRegistration(
            id: profile.id,
            profile: profile,
            bundleIdentifiers: profile.applicationIdentifiers,
            bundleIdentifierPrefix: profile.applicationBundlePrefix,
            placeClass: builtIn?.placeClass
                ?? profile.perception?.placeClass
                ?? .dataSource,
            displayName: builtIn?.displayName ?? profile.title,
            perception: profile.perception,
            legacyAttention: builtIn)
    }
}
