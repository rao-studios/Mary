//
//  MediaSurfaceLaunch.swift
//  MaryPlugin
//
//  WHAT: Open a declared player and wait until it is running.
//  IN:   play_playlist / shuffle_playlist when resolve is nil
//  OUT:  registration + pid
//  PIN:  Named first; only-declared if unnamed; never guess among several.
//

import AppKit
import Foundation
import MaryAmbient

public enum MediaSurfaceLaunch {

    public static let timeout: TimeInterval = 8

    /// Which declared player to start. Running resolve is the caller's first try.
    public static func launchTarget(
        named: String?,
        declared: [MediaSurfaceRegistration]
    ) -> MediaSurfaceRegistration? {
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            return declared.first {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: named)
            }
        }
        guard declared.count == 1 else { return nil }
        return declared[0]
    }

    /// Running player, or launch the one `launchTarget` names.
    public static func resolveOrLaunch(
        named: String?,
        support: MediaSurfaceSupport = .shared
    ) async -> (MediaSurfaceRegistration, pid_t)? {
        if let hit = support.resolve(named) { return hit }
        guard let target = launchTarget(named: named, declared: support.all())
        else { return nil }
        guard await open(target) else { return nil }
        return await wait(for: target)
    }

    /// NSWorkspace only — `/usr/bin/open` is `WindowManagement`'s subprocess
    /// errand alone (`NoAppleEventsTests.testSubprocessOnlyRunsMaryOwnedTools`
    /// names it as the one file this build lets touch a shell tool that way).
    /// A bundle identifier `urlForApplication` cannot resolve honestly fails
    /// to launch rather than reaching for a second road to the same effect.
    private static func open(_ registration: MediaSurfaceRegistration) async -> Bool {
        guard let bundle = registration.bundleIdentifiers.first,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private static func wait(
        for registration: MediaSurfaceRegistration
    ) async -> (MediaSurfaceRegistration, pid_t)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = MediaSurfaceSupport.pid(of: registration) {
                return (registration, pid)
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }
}
