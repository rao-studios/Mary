//
//  MediaSurfaceSupport.swift
//  MaryPlugin
//
//  THE ROSTER OF DECLARED TRANSPORTS — `ProseSurfaceSupport`'s twin.
//
//  Reconciled wholesale on every package activation, for the same reason:
//  a package that stops declaring a transport must stop having one, and a
//  merge would leave a stale declaration answering for a player that no
//  longer claims it.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class MediaSurfaceSupport: @unchecked Sendable {

    public static let shared = MediaSurfaceSupport()

    private let box = OSAllocatedUnfairLock<[String: MediaSurfaceRegistration]>(
        initialState: [:])

    public init() {}

    public func reconcile(_ registrations: [MediaSurfaceRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [MediaSurfaceRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    public func registration(applicationID: String) -> MediaSurfaceRegistration? {
        box.withLock { $0[applicationID] }
    }

    public func registration(bundleID: String) -> MediaSurfaceRegistration? {
        box.withLock { map in map.values.first { $0.owns(bundleID: bundleID) } }
    }

    /// The registration behind a place, when that place is a declared player.
    /// A lane is never one.
    public func registration(place: AmbientPlace) -> MediaSurfaceRegistration? {
        guard case .application(let id) = place else { return nil }
        return registration(applicationID: id) ?? registration(bundleID: id)
    }

    public static func pid(of registration: MediaSurfaceRegistration) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier.map(registration.owns) ?? false
        }?.processIdentifier
    }

    /// The declared player that is actually running, preferring the one named.
    ///
    /// NAMED FIRST, THEN WHICHEVER IS RUNNING. With one player installed the
    /// distinction is invisible; with two it is the difference between "pause
    /// the music" pausing what the user meant and pausing whichever package
    /// happened to sort first.
    public func resolve(_ named: String?) -> (MediaSurfaceRegistration, pid_t)? {
        if let named, !named.isEmpty {
            let match = all().first {
                $0.applicationID.caseInsensitiveCompare(named) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(named) == .orderedSame
                    || $0.owns(bundleID: named)
            }
            if let match, let pid = Self.pid(of: match) { return (match, pid) }
            if match != nil { return nil }
        }
        for registration in all() {
            if let pid = Self.pid(of: registration) { return (registration, pid) }
        }
        return nil
    }
}
