//
//  CodeSurfaceSupport.swift
//  MaryPlugin
//
//  THE REGISTRY OF DECLARED CODE SURFACES.
//
//  A facade over `SurfaceRoster`. There is no backing resolver to install
//  here: a code surface is read-only. This registry answers which application
//  owns a place, what its declared code coordinates are, and which process
//  the pair session is in.
//

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
