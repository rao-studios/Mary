//
//  CodeSurfacePollTarget.swift
//  MaryPlugin
//
//  WHICH CODE SURFACE TO WALK THIS POLL — frontmost when it is one, the
//  standing coding workspace when the user is speaking to Mary.
//
//  THE FAILURE THIS CLOSES. `CodeSurfaceObserver.pollOnce` used to require
//  `NSWorkspace.frontmostApplication` to be a declared editor. Mary's own
//  window is the commonest frontmost on a spoken turn, so the first "what
//  do you think about this code" skipped the walk, left `liveWork` empty,
//  and Lane A hit the blindness clause ("paste the code") while Xcode was
//  still running. The follow-up then read the buffer — expected — after
//  the turn had already spoken. A coding workspace that is active in
//  AmbientWorld is the realm to sample; Mary's overlay is transparent to
//  that choice, the same way it is transparent to the focus tracker.
//
//  Safari / Pages / a browser in front is NOT this case: those are real
//  destinations, and pulling a background Xcode into `hasCoding` would
//  steal unled turns. Only a workspace-transparent frontmost (Mary,
//  system chrome, or nobody) falls through to the standing editor.
//

import Foundation
import MaryAmbient
import MaryFoundation

public enum CodeSurfacePollTarget {

    public struct Process: Equatable, Sendable {
        public var bundleID: String
        public var pid: pid_t

        public init(bundleID: String, pid: pid_t) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public struct Hit: Equatable, Sendable {
        public var registration: CodeSurfaceRegistration
        public var pid: pid_t
        /// True when the hit is the frontmost application. A miss against a
        /// frontmost editor retracts (the file closed). A miss against a
        /// standing background editor must not — the user asked Mary with
        /// her own window up, and yesterday's caret is still the claim.
        public var isFrontmost: Bool

        public init(
            registration: CodeSurfaceRegistration,
            pid: pid_t,
            isFrontmost: Bool
        ) {
            self.registration = registration
            self.pid = pid
            self.isFrontmost = isFrontmost
        }
    }

    /// Pure. Callers supply the frontmost bundle, the running processes, and
    /// the preferred application ids (standing caret, then tracker lead) so
    /// a test never needs Accessibility or a live Xcode.
    public static func resolve(
        frontmostBundleID: String?,
        maryBundleID: String?,
        registrations: [CodeSurfaceRegistration],
        running: [Process],
        preferredApplicationIDs: [String]
    ) -> Hit? {
        func registration(owning bundleID: String) -> CodeSurfaceRegistration? {
            registrations.first { $0.owns(bundleID: bundleID) }
        }
        func process(ownedBy registration: CodeSurfaceRegistration) -> Process? {
            running.first { registration.owns(bundleID: $0.bundleID) }
        }

        if let frontmostBundleID,
           let registration = registration(owning: frontmostBundleID),
           let process = process(ownedBy: registration) {
            return Hit(
                registration: registration, pid: process.pid, isFrontmost: true)
        }

        guard WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: frontmostBundleID, maryBundleID: maryBundleID)
        else { return nil }

        for applicationID in preferredApplicationIDs {
            if let registration = registrations.first(where: {
                $0.applicationID == applicationID
            }), let process = process(ownedBy: registration) {
                return Hit(
                    registration: registration, pid: process.pid, isFrontmost: false)
            }
        }

        for registration in registrations.sorted(by: {
            $0.applicationID < $1.applicationID
        }) {
            if let process = process(ownedBy: registration) {
                return Hit(
                    registration: registration, pid: process.pid, isFrontmost: false)
            }
        }
        return nil
    }
}
