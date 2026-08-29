//
//  CodeSurfaceSupport.swift
//  MaryPlugin
//
//  THE REGISTRY OF DECLARED CODE SURFACES.
//
//  `ProseSurfaceSupport`'s sibling, and considerably smaller: there is no
//  backing resolver to install here. A prose surface points the passage
//  verbs at a reader AND a writer; a code surface is read-only, so there is
//  no write-side machinery anywhere in Mary for it to back. This registry
//  answers exactly two questions: which application owns a place, and what
//  are its declared code coordinates.
//
//  FROZEN-SWAP, not mutate-in-place, for the same reason `ProseSurfaceSupport`
//  is: reconciliation replaces the whole map behind a lock and readers take a
//  snapshot, so a turn that started reading finishes against the roster it
//  started with rather than half of two.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class CodeSurfaceSupport: @unchecked Sendable {

    public static let shared = CodeSurfaceSupport()

    private let box = OSAllocatedUnfairLock<[String: CodeSurfaceRegistration]>(
        initialState: [:])

    public init() {}

    // MARK: - The roster

    /// Replaces the declared surfaces wholesale.
    ///
    /// Called on every package activation. A REPLACE rather than a merge for
    /// the same reason `ProseSurfaceSupport.reconcile` is: a package that
    /// stops declaring a code surface must stop having one.
    public func reconcile(_ registrations: [CodeSurfaceRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [CodeSurfaceRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    public func registration(applicationID: String) -> CodeSurfaceRegistration? {
        box.withLock { $0[applicationID] }
    }

    public func registration(bundleID: String) -> CodeSurfaceRegistration? {
        box.withLock { map in map.values.first { $0.owns(bundleID: bundleID) } }
    }

    public static func pid(of registration: CodeSurfaceRegistration) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier.map(registration.owns) ?? false
        }?.processIdentifier
    }
}
