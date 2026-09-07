//
//  SurfaceRoster.swift
//  MaryAmbient
//
//  WHAT: Frozen-swap registry for any SurfaceClaim.
//  IN:   package declarations
//  OUT:  resolve → SurfacePollTarget.pairHit
//  PIN:  Wholesale reconcile, never merge — a dropped declaration must stop answering.
//
import Foundation
import os

public final class SurfaceRoster<C: SurfaceClaim>: @unchecked Sendable {

    private let box = OSAllocatedUnfairLock<[String: C]>(initialState: [:])

    public init() {}

    /// Replaces the declared surfaces wholesale.
    public func reconcile(_ registrations: [C]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [C] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    public func registration(applicationID: String) -> C? {
        box.withLock { $0[applicationID] }
    }

    public func registration(bundleID: String) -> C? {
        box.withLock { map in map.values.first { $0.owns(bundleID: bundleID) } }
    }

    public static func pid(of claim: C) -> pid_t? {
        SurfacePollTarget.pid(
            of: claim, running: SurfacePollTarget.runningProcesses())
    }

    /// Named first if that process is running; else the pair-session hit;
    /// else a standing claim answers regardless of who is frontmost; else,
    /// when `anyRunningFallback`, the first running member.
    public func resolve(
        named: String?,
        standingApplicationID: String? = nil,
        unpreferredFallback: Bool = false,
        anyRunningFallback: Bool = false
    ) -> (C, pid_t)? {
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            let claims = all()
            if let match = claims.first(where: {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: named)
            }), let pid = Self.pid(of: match) {
                return (match, pid)
            }
            // WHAT THE PERSON CALLS IT, which is rarely its id or its full
            // title.
            //
            // PIN: MEASURED. Apple Music's registration is id `apple-music`,
            // display name "Apple Music", bundle `com.apple.Music` — so a caller
            // saying `app: "Music"`, which is what the app is called on the
            // machine and what a model writes, matched none of the three and the
            // whole resolution returned nil. The aliases that answer this are
            // already declared by the package (`plugin.application.aliases`) and
            // already indexed; this rung asks the index instead of adding a
            // fourth spelling to every claim.
            let index = AmbientApplicationIndexProvider.current
            guard let registration = index.all.first(where: { candidate in
                candidate.profile.aliases.contains { $0.lowercased() == wanted }
            }) else { return nil }
            let identity = registration.id.lowercased()
            if let match = claims.first(where: { claim in
                claim.applicationID.lowercased() == identity
                    || registration.bundleIdentifiers.contains(where: claim.owns(bundleID:))
            }), let pid = Self.pid(of: match) {
                return (match, pid)
            }
            return nil
        }
        if let hit = SurfacePollTarget.pairHit(
            claims: all(),
            standingApplicationID: standingApplicationID,
            unpreferredFallback: unpreferredFallback),
           let claim = registration(applicationID: hit.applicationID) {
            return (claim, hit.pid)
        }
        // `pairHit`'s frontmost-transparency guard is ambient-poll discipline
        // — it must not sample a random running app while some other
        // workspace is in front. It is not a veto on the user's own request:
        // a standing claim (a surface this family is already watching) still
        // answers an explicit call regardless of who is frontmost.
        if let standingApplicationID,
           let claim = registration(applicationID: standingApplicationID),
           let pid = Self.pid(of: claim) {
            return (claim, pid)
        }
        guard anyRunningFallback else { return nil }
        for claim in all() {
            if let pid = Self.pid(of: claim) { return (claim, pid) }
        }
        return nil
    }
}
