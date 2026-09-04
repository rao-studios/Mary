//
//  WebSurfaceSupport.swift
//  MaryPlugin
//
//  WHAT: Roster of declared browsers, and which one a turn means.
//  IN:   AbilityRuntime.Snapshot.webSurfaceRegistrations()  OUT: WebSurfaceAdapter
//  PIN:  THE BROWSER IS ONE PLACE, SERVED BY SEVERAL PROCESSES. AmbientPlaceResolver
//        collapses Safari and Chrome into the single logical place "browser", so a
//        lookup keyed on the place has to ask the focus ledger WHICH engine was there —
//        `registration(applicationID:)` would find nothing for "browser".
//        THE LADDER NEVER GUESSES BETWEEN TWO VISIBLE BROWSERS. Ambiguity answers nil;
//        the turn loop's own fallback (first browsing profile, which sorts to Chrome)
//        is deliberately not reachable from here.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

public final class WebSurfaceSupport: @unchecked Sendable {

    public static let shared = WebSurfaceSupport()

    private let roster = SurfaceRoster<WebSurfaceRegistration>()

    public init() {}

    public func reconcile(_ registrations: [WebSurfaceRegistration]) {
        roster.reconcile(registrations)
    }

    public func all() -> [WebSurfaceRegistration] { roster.all() }

    public func registration(applicationID: String) -> WebSurfaceRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public func registration(bundleID: String) -> WebSurfaceRegistration? {
        roster.registration(bundleID: bundleID)
    }

    /// The browser behind a place. The logical browser workspace resolves through the
    /// focus ledger, because the place itself does not say which engine.
    public func registration(place: AmbientPlace) -> WebSurfaceRegistration? {
        guard case .application(let id) = place else { return nil }
        if id == AmbientPlaceResolver.browserApplicationID {
            guard let evidenced = WorkspaceFocusTracker.shared
                .evidenceProcess(for: AmbientPlaceResolver.browserPlace)
                ?? WorkspaceFocusTracker.shared.evidenceProcess(
                    for: AmbientPlaceResolver.browserPlace,
                    within: WorkspaceFocusTracker.signalHorizon)
            else { return nil }
            return registration(bundleID: evidenced)
        }
        return registration(applicationID: id) ?? registration(bundleID: id)
    }

    public static func pid(of registration: WebSurfaceRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }

    /// Which browser a turn means, and the process serving it.
    public func resolve(_ named: String? = nil) -> (WebSurfaceRegistration, pid_t)? {
        let bundleID = BrowserTargetResolution.bundleID(
            named: named.flatMap { name in
                roster.all().first { candidate in
                    candidate.applicationID.caseInsensitiveCompare(name) == .orderedSame
                        || candidate.displayName.lowercased().contains(name.lowercased())
                        || candidate.owns(bundleID: name)
                }?.bundleIdentifiers.first
            },
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            freshEvidence: WorkspaceFocusTracker.shared
                .evidenceProcess(for: AmbientPlaceResolver.browserPlace),
            recentEvidence: WorkspaceFocusTracker.shared.evidenceProcess(
                for: AmbientPlaceResolver.browserPlace,
                within: WorkspaceFocusTracker.signalHorizon),
            onScreen: BrowserTargetResolution.onScreenBundleIDs(),
            running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
            isBrowser: { [weak self] candidate in
                self?.registration(bundleID: candidate) != nil
            })
        guard let bundleID,
              let registration = self.registration(bundleID: bundleID),
              let pid = Self.pid(of: registration)
        else { return nil }
        return (registration, pid)
    }

    /// Every declared browser that is running right now — what an ambiguity says.
    public func runningDisplayNames() -> [String] {
        roster.all()
            .filter { Self.pid(of: $0) != nil }
            .map(\.displayName)
            .sorted()
    }
}
