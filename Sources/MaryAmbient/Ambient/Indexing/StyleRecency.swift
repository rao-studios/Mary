//
//  StyleRecency.swift
//  MaryAmbient
//
//  WHAT: How style evidence ages. One mechanism, and only one.
//  IN:   StyleEvidence tally / eviction sweep
//  OUT:  weight(age:) — 2^(-age/halfLife)
//  PIN:  Facts cliff; habits drift. Weight halves every halfLife. Floor at two half-lives.
//
import Foundation

/// Pure time arithmetic, shared by the tally and the eviction sweep.
public enum StyleRecency {

    /// A contribution's weight halves every thirty days. Long enough that a steady practice
    /// holds its confidence across a quiet fortnight, short enough that a fortnight of doing
    /// something differently is already winning.
    public static let halfLife: TimeInterval = 60 * 60 * 24 * 30

    /// Below this share of its original weight a contribution stops counting and is swept. Two
    /// half-lives.
    public static let decayFloor = 0.25

    /// `2^(-age/halfLife)`, clamped to 0…1. A contribution from the future (a clock skew, a
    /// restored timestamp) weighs exactly 1 rather than more — evidence cannot count for more
    /// than itself just because a date is wrong.
    public static func weight(
        age: TimeInterval, halfLife: TimeInterval = StyleRecency.halfLife
    ) -> Double {
        guard halfLife > 0 else { return age <= 0 ? 1 : 0 }
        guard age > 0 else { return 1 }
        return pow(2, -age / halfLife)
    }

    public static func weight(
        at observed: Date, now: Date, halfLife: TimeInterval = StyleRecency.halfLife
    ) -> Double {
        weight(age: now.timeIntervalSince(observed), halfLife: halfLife)
    }
}
