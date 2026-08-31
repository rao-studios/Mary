//
//  CodeSurfaceSupport.swift
//  MaryPlugin
//
//  WHAT: Registry of declared code surfaces (SurfaceRoster facade).
//  PIN:  Read-only roster — no backing writer to install.

import Foundation
import MaryAmbient
import MaryFoundation

public final class CodeSurfaceSupport: @unchecked Sendable {

    public static let shared = CodeSurfaceSupport()

    private let roster = SurfaceRoster<CodeSurfaceRegistration>()

    public init() {}

    public func reconcile(_ registrations: [CodeSurfaceRegistration]) {
        roster.reconcile(registrations)
    }

    public func all() -> [CodeSurfaceRegistration] { roster.all() }

    public func registration(applicationID: String) -> CodeSurfaceRegistration? {
        roster.registration(applicationID: applicationID)
    }

    public func registration(bundleID: String) -> CodeSurfaceRegistration? {
        roster.registration(bundleID: bundleID)
    }

    public static func pid(of registration: CodeSurfaceRegistration) -> pid_t? {
        SurfaceRoster.pid(of: registration)
    }

    /// Named editor if running; else the standing pair-session hit; else the
    /// editor `CodeSurfaceObserver` already holds a claim on, whoever is
    /// frontmost — an explicit "read my code" answers the surface Mary is
    /// already watching, not whichever window happens to be in front while
    /// the user is talking to her. Falls back to any running editor last.
    public func resolve(_ named: String?) -> (CodeSurfaceRegistration, pid_t)? {
        roster.resolve(
            named: named,
            standingApplicationID: CodeSurfaceObserver.shared.observedPlace?.application,
            unpreferredFallback: true,
            anyRunningFallback: true)
    }
}
