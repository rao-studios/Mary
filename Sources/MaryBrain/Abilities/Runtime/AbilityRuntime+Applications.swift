//
//  AbilityRuntime+Applications.swift
//  MaryBrain
//
//  WHAT: Which application this turn is about.
//  IN:   installed profiles + the injected focus resolver
//  OUT:  application id for the roster hoist and provider ladder
//  PIN:  The injected resolver is the turn's already-arbitrated answer; the
//        frontmost bundle id is only the fallback.
//
import AppKit
import Foundation

extension AbilityRuntime {

    public var applicationProfiles: [ApplicationProfile] {
        nativeProfiles + abilitySnapshot.plugins.applicationProfiles
    }
    /// The pinned application, as a PROFILE id.
    ///
    /// PIN: RESOLVED THROUGH THE PROFILES, like the focused rung beside it — a
    /// pin names a registration's logical id, and a rung that answered with an
    /// id no profile knows would assert a provider nothing can serve.
    public var pinnedApplicationID: String? {
        guard let pinned = pinnedProvider?() else { return nil }
        return applicationProfiles.first {
            $0.id.caseInsensitiveCompare(pinned) == .orderedSame
        }?.id
    }

    public var focusedApplicationID: String? {
        // Injected focus resolver — the turn's already-arbitrated answer.
        if let resolvedOwner = focusProvider?(),
           let resolved = applicationProfiles.first(where: {
               $0.id.caseInsensitiveCompare(resolvedOwner) == .orderedSame
           }) {
            return resolved.id
        }
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier?.lowercased() else { return nil }
        return Self.applicationID(
            forBundleIdentifier: bundleIdentifier,
            profiles: applicationProfiles)
    }

    static func applicationID(
        forBundleIdentifier bundleIdentifier: String,
        profiles: [ApplicationProfile]
    ) -> String? {
        let bundleIdentifier = bundleIdentifier.lowercased()
        if let exact = profiles.first(where: { profile in
            profile.applicationIdentifiers.contains {
                $0.lowercased() == bundleIdentifier
            }
        }) {
            return exact.id
        }
        return profiles.first { profile in
            guard let prefix = profile.applicationBundlePrefix else {
                return false
            }
            return PluginApplicationSchema.bundleIdentifier(
                bundleIdentifier,
                isInFamily: prefix)
        }?.id
    }
}
