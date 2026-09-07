//
//  SurfacePollTarget.swift
//  MaryAmbient
//
//  WHAT: Which process to sample while they speak to Mary — the ingested-app standard.
//  IN:   SurfaceClaim / ApplicationRegistration
//  OUT:  SurfaceRoster.resolve. Durable expertise → AbilityTotemTarget
//  PIN:  A new .mary app joins the roster; it does not get a code-named cousin of this type.
//

import AppKit
import Foundation

/// A roster member that can own a running process. Logical `applicationID` is never a
/// bundle identifier. `displayName` is what the user called it, for named Skill targeting.
public protocol SurfaceClaim: Sendable {
    var applicationID: String { get }
    var displayName: String { get }
    func owns(bundleID: String) -> Bool
}

/// Exact identity, then `ApplicationRegistration.isInFamily` on an optional
/// prefix. The default membership answer for a declared surface.
public enum SurfaceClaimOwnership {

    public static func exactThenFamily(
        bundleID: String,
        identifiers: some Sequence<String>,
        prefix: String?
    ) -> Bool {
        let lowered = bundleID.lowercased()
        if identifiers.contains(where: { $0.lowercased() == lowered }) {
            return true
        }
        guard let prefix = prefix?.lowercased(), !prefix.isEmpty else { return false }
        return ApplicationRegistration.isInFamily(lowered, prefix: prefix)
    }

    /// CORPUS MEMBERSHIP. Each declared identity is a stem: `…scrivener` claims `…scrivener3`,
    /// and `…Xcode` claims `…Xcode-beta`.
    public static func declaredStem(
        bundleID: String,
        identifiers: some Sequence<String>
    ) -> Bool {
        let lowered = bundleID.lowercased()
        return identifiers.contains { lowered.hasPrefix($0.lowercased()) }
    }
}

public enum SurfacePollTarget {

    /// A running process as macOS reports it, before anything is resolved into
    /// Mary's vocabulary. Not a `SourceScope`: this is the INPUT to identity
    /// resolution, and a scope of eight nils would say less.
    public struct Process: Equatable, Sendable {
        public var bundleID: String
        public var pid: pid_t
        /// A regular application, as opposed to a helper that answers to the
        /// family's prefix and can never be frontmost.
        public var isRegular: Bool

        public init(bundleID: String, pid: pid_t, isRegular: Bool = true) {
            self.bundleID = bundleID
            self.pid = pid
            self.isRegular = isRegular
        }
    }

    public struct Hit: Equatable, Sendable {
        /// The LOGICAL application id, already resolved — see `place`.
        public var applicationID: String
        public var pid: pid_t
        /// True when the hit is the frontmost application. A miss against a frontmost editor
        /// retracts (the file closed).
        public var isFrontmost: Bool

        /// The hit as a place, through the one resolution ladder. Callers that want
        /// to name where this is — a log line, a trace row — say it this way rather
        /// than re-deriving a display name from the raw id.
        public var place: AmbientPlace {
            AmbientApplicationIndexProvider.current.registration(id: applicationID)?.place
                ?? .application(applicationID)
        }

        public init(applicationID: String, pid: pid_t, isFrontmost: Bool) {
            self.applicationID = applicationID
            self.pid = pid
            self.isFrontmost = isFrontmost
        }
    }

    /// Pure pid lookup over an injected running-process list.
    ///
    /// PIN: THE REGULAR MEMBER OF THE FAMILY, NEVER A HELPER. A claim owns a
    /// bundle family by prefix, and a browser's renderers and GPU helpers answer
    /// to that prefix too; the first process met was whichever the system
    /// listed first, and a helper can never come forward — measured as an
    /// activation that "refused" forever. A helper is taken only when no
    /// regular member is running at all, which is a claim about a process that
    /// exists, not about one that can be staged.
    public static func pid(
        of claim: some SurfaceClaim, running: [Process]
    ) -> pid_t? {
        process(ownedBy: claim, running: running)?.pid
    }

    static func process<C: SurfaceClaim>(ownedBy claim: C, running: [Process]) -> Process? {
        let owned = running.filter { claim.owns(bundleID: $0.bundleID) }
        return owned.first(where: \.isRegular) ?? owned.first
    }

    /// Live `NSWorkspace` snapshot for Support wrappers and production polls.
    public static func runningProcesses(
        from applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [Process] {
        applications.compactMap { application in
            guard let bundleID = application.bundleIdentifier else { return nil }
            return Process(
                bundleID: bundleID, pid: application.processIdentifier,
                isRegular: application.activationPolicy == .regular)
        }
    }

    /// Which claimed process to walk this poll. `unpreferredFallback` (default true): a
    /// declared-surface roster may sample any running member when Mary is up and nothing is
    /// standing. Ambient must pass false — it must not pick a random running app.
    public static func resolve<C: SurfaceClaim>(
        frontmostBundleID: String?,
        maryBundleID: String?,
        claims: [C],
        running: [Process],
        preferredApplicationIDs: [String],
        unpreferredFallback: Bool = true
    ) -> Hit? {
        func process(ownedBy claim: C) -> Process? {
            Self.process(ownedBy: claim, running: running)
        }

        if let frontmostBundleID,
           let claim = claims.first(where: { $0.owns(bundleID: frontmostBundleID) }),
           let process = process(ownedBy: claim) {
            return Hit(
                applicationID: claim.applicationID,
                pid: process.pid,
                isFrontmost: true)
        }

        guard WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: frontmostBundleID, maryBundleID: maryBundleID)
        else { return nil }

        for applicationID in preferredApplicationIDs {
            if let claim = claims.first(where: { $0.applicationID == applicationID }),
               let process = process(ownedBy: claim) {
                return Hit(
                    applicationID: claim.applicationID,
                    pid: process.pid,
                    isFrontmost: false)
            }
        }

        guard unpreferredFallback else { return nil }
        for claim in claims.sorted(by: { $0.applicationID < $1.applicationID }) {
            if let process = process(ownedBy: claim) {
                return Hit(
                    applicationID: claim.applicationID,
                    pid: process.pid,
                    isFrontmost: false)
            }
        }
        return nil
    }

    /// Preferred ids for a pair-session poll: the standing publication, then
    /// the tracker lead. Empty entries are dropped; order is the ladder.
    public static func preferredApplicationIDs(
        standing: String?,
        lead: String? = WorkspaceFocusTracker.shared.leadPlace()?.application
    ) -> [String] {
        [standing, lead].compactMap { $0 }
    }

    /// Production poll: live frontmost, live running list, Mary as transparent.
    public static func pairHit<C: SurfaceClaim>(
        claims: [C],
        standingApplicationID: String?,
        unpreferredFallback: Bool = true
    ) -> Hit? {
        let front = NSWorkspace.shared.frontmostApplication
        return resolve(
            frontmostBundleID: front?.bundleIdentifier,
            maryBundleID: Bundle.main.bundleIdentifier,
            claims: claims,
            running: runningProcesses(),
            preferredApplicationIDs: preferredApplicationIDs(
                standing: standingApplicationID),
            unpreferredFallback: unpreferredFallback)
    }
}
