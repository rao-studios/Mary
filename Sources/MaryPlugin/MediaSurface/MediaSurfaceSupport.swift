//
//  MediaSurfaceSupport.swift
//  MaryPlugin
//
//  WHAT: Roster of declared transports. Wholesale reconcile.
//  PIN:  Twin of ProseSurfaceSupport — a dropped declaration must stop answering.

import Foundation
import MaryAmbient
import MaryFoundation

public final class MediaSurfaceSupport: @unchecked Sendable {

    public static let shared = MediaSurfaceSupport()

    private let roster = SurfaceRoster<MediaSurfaceRegistration>()

    public init() {}

    public func reconcile(_ registrations: [MediaSurfaceRegistration]) {
        roster.reconcile(registrations)
    }

    public func all() -> [MediaSurfaceRegistration] { roster.all() }

    public func registration(applicationID: String) -> MediaSurfaceRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public func registration(bundleID: String) -> MediaSurfaceRegistration? {
        roster.registration(bundleID: bundleID)
    }

    /// The registration behind a place, when that place is a declared player.
    /// A lane is never one.
    public func registration(place: AmbientPlace) -> MediaSurfaceRegistration? {
        guard case .application(let id) = place else { return nil }
        return registration(applicationID: id) ?? registration(bundleID: id)
    }

    public static func pid(of registration: MediaSurfaceRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }

    /// Named first, else the standing pair-session hit, else whichever
    /// declared player is running.
    public func resolve(_ named: String?) -> (MediaSurfaceRegistration, pid_t)? {
        roster.resolve(
            named: named,
            unpreferredFallback: true,
            anyRunningFallback: true)
    }
}
