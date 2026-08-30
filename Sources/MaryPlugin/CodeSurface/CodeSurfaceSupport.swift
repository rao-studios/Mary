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

    /// Named editor if running; else the standing pair-session hit.
    public func resolve(_ named: String?) -> (CodeSurfaceRegistration, pid_t)? {
        roster.resolve(named: named)
    }
}
