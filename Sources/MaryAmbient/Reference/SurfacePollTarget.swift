//
//  SurfacePollTarget.swift
//  MaryAmbient
//
//  THE STANDARD FOR INGESTED APPLICATIONS. An application Mary can ingest,
//  learn, and understand is data: a package, a claim on a process, a
//  discipline it extends, and an Ability Totem target. If a utility can be
//  answered from those, it is generic. A new `.mary` application joins the
//  roster; it does not get a code-named cousin of this type.
//
//  THREE QUESTIONS, ONE JOIN:
//    1. Who claims this process? `SurfaceClaim` — `applicationID` and
//       `owns(bundleID:)`. Every declared surface registration and
//       `ApplicationRegistration` answers it.
//    2. Which process do we sample while they speak to Mary? This file.
//       Frontmost if it is in this roster; otherwise the standing workspace
//       when the frontmost process is workspace-transparent (Mary's overlay,
//       system chrome). Roster-scoped so Pages in front does not pull Xcode.
//    3. Where does what we learned live? `AbilityTotemTarget` — this Ability,
//       and for application expertise the disciplines it extends. Not a
//       code-totem, prose-totem, or web-totem.
//
//  PAIR SESSION — THE OBSERVER CONTRACT THIS HIT SERVES. Mary sits in the
//  live work before she speaks: compose and revise as you talk, across every
//  discipline, not only coding. Surface observers (and unnamed Skill /
//  faculty targeting) must keep:
//    · Eyes before Skills. Standing caret/window text rides the turn so Lane A
//      does not ask for a paste. A Skill is not how Mary first sees the work.
//    · Mary's overlay is not blindness. Resolve through this file, never
//      `frontmostApplication` alone.
//    · A highlight outranks a caret. Retract the pair-caret fact when
//      selection owns the ground; do not publish two authorities for "where
//      they are."
//    · No application-shaped observer API. `observedPlace` comes from the
//      registration this hit named. Adding an ingested app must not add a
//      Swift case.
//    · One pair lead. Caret liveWork and corpus neighbourhood may merge for
//      the same place; coding and writing fulls must not coexist.
//    · Hands stay discipline-specific. Disk vs AX write policy is not this
//      file's question.
//
//  WHAT STAYS PER SURFACE is the walk AFTER the pid (caret excerpt, corpus
//  title, AX ambient context, later a page or transport) and the schema of
//  the declaration. Write policy stays specific too.
//
//  `CodeSurfacePollTarget` was a local, code-named instance of question 2
//  for the Xcode-behind-Mary paste miss. The policy was never coding-specific.
//

import AppKit
import Foundation

/// A roster member that can own a running process.
///
/// Logical `applicationID` is never a bundle identifier. `displayName` is
/// what the user called it, for named Skill targeting. `owns(bundleID:)` is
/// the one membership predicate — exact ids first, then a declared family
/// (`SurfaceClaimOwnership.exactThenFamily`). A corpus may still prefix-match
/// declared identities; that looser rule is pinned, not silent.
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

    /// CORPUS MEMBERSHIP. Each declared identity is a stem: `…scrivener`
    /// claims `…scrivener3`, and `…Xcode` claims `…Xcode-beta`. `isInFamily`
    /// refuses a hyphen after the stem, so unifying corpus onto that
    /// predicate would drop those processes. Keep the stem match, and refuse
    /// a different word with no separator (`…XcodeHelper` still matches
    /// `hasPrefix` — that looseness is why family-boundary owns is preferred
    /// everywhere a package can declare a prefix).
    public static func declaredStem(
        bundleID: String,
        identifiers: some Sequence<String>
    ) -> Bool {
        let lowered = bundleID.lowercased()
        return identifiers.contains { lowered.hasPrefix($0.lowercased()) }
    }
}

public enum SurfacePollTarget {

    public struct Process: Equatable, Sendable {
        public var bundleID: String
        public var pid: pid_t

        public init(bundleID: String, pid: pid_t) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public struct Hit: Equatable, Sendable {
        public var applicationID: String
        public var pid: pid_t
        /// True when the hit is the frontmost application. A miss against a
        /// frontmost editor retracts (the file closed). A miss against a
        /// standing background editor must not — the user asked Mary with
        /// her own window up, and yesterday's caret is still the claim.
        public var isFrontmost: Bool

        public init(applicationID: String, pid: pid_t, isFrontmost: Bool) {
            self.applicationID = applicationID
            self.pid = pid
            self.isFrontmost = isFrontmost
        }
    }

    /// Pure pid lookup over an injected running-process list.
    public static func pid(
        of claim: some SurfaceClaim, running: [Process]
    ) -> pid_t? {
        running.first { claim.owns(bundleID: $0.bundleID) }?.pid
    }

    /// Live `NSWorkspace` snapshot for Support wrappers and production polls.
    public static func runningProcesses(
        from applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [Process] {
        applications.compactMap { application in
            guard let bundleID = application.bundleIdentifier else { return nil }
            return Process(bundleID: bundleID, pid: application.processIdentifier)
        }
    }

    /// Which claimed process to walk this poll.
    ///
    /// `unpreferredFallback` (default true): a declared-surface roster may
    /// sample any running member when Mary is up and nothing is standing.
    /// Ambient must pass false — it must not pick a random running app.
    public static func resolve<C: SurfaceClaim>(
        frontmostBundleID: String?,
        maryBundleID: String?,
        claims: [C],
        running: [Process],
        preferredApplicationIDs: [String],
        unpreferredFallback: Bool = true
    ) -> Hit? {
        func process(ownedBy claim: C) -> Process? {
            running.first { claim.owns(bundleID: $0.bundleID) }
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
