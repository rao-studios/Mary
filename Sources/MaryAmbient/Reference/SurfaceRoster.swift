//
//  SurfaceRoster.swift
//  MaryAmbient
//
//  FROZEN-SWAP REGISTRY FOR ANY `SurfaceClaim`. Code, prose, media, and
//  corpus Support types are facades over this machine: lock, wholesale
//  reconcile, snapshot reads. A package that stops declaring a surface must
//  stop having one — a merge would leave the old declaration answering.
//
//  Skill targeting is the pair-session hit asked at call time: named match
//  (id / displayName / owns) if that process is running, else the standing
//  workspace while Mary is front, else (media) any running member.
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
    /// else, when `anyRunningFallback`, the first running member.
    public func resolve(
        named: String?,
        standingApplicationID: String? = nil,
        unpreferredFallback: Bool = false,
        anyRunningFallback: Bool = false
    ) -> (C, pid_t)? {
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            if let match = all().first(where: {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: named)
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
        guard anyRunningFallback else { return nil }
        for claim in all() {
            if let pid = Self.pid(of: claim) { return (claim, pid) }
        }
        return nil
    }
}
