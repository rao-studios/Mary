//
//  StyleRecency.swift
//  MaryAmbient
//
//  How evidence ages. One mechanism, and only one.
//
//  THE ONLY CONTINUOUS TIME-WEIGHTING IN THIS CODEBASE. Everything else that
//  ages — `AmbientFact.freshFor`, `WorkspaceFocusTracker.signalHorizon`, a
//  surface past its expiry — is a cliff: inside the window it
//  counts fully, outside it counts for nothing. That is right for a fact about
//  the machine right now, and wrong for a habit. A person does not stop
//  writing one way on a Tuesday; they drift, and a cliff cannot see a drift.
//
//  So a contribution's weight halves every `halfLife`. A practice you are
//  moving away from loses the lead while its evidence is still present, which
//  is what makes a change of habit visible as it happens rather than as a jolt
//  six weeks later.
//
//  WHAT THIS REPLACED, and why the replacement is gentler rather than harsher.
//
//  There used to be four more moving parts: a stale stage at 3 days, an
//  eviction at 7, a 45-day policy horizon, and a work clock counting only the
//  days the corpus observed anything — that last one existing to stop a week
//  away from the desk wiping a profile. All four were calibrated when a single
//  focus event filed opinions from twenty-four files, so evidence was
//  abundant and could afford to be thrown away quickly. Evidence now arrives
//  only from files the user actually changed, which is far scarcer, and a
//  7-day sweep would empty the corpus faster than it could fill.
//
//  Honestly stated: each contribution still falls silent at exactly two
//  half-lives — the floor is a threshold, and a threshold is a small cliff.
//  What changed is WHERE it sits and what it takes down: sixty days instead of
//  seven, per contribution instead of per row, so a row fades
//  contribution-by-contribution as their dates differ rather than vanishing at
//  once. The work clock went with the old cliff: what made a holiday dangerous
//  was losing everything at day seven, and under this curve a fortnight away
//  costs a quarter of a contribution's weight and deletes nothing.
//

import Foundation

/// Pure time arithmetic, shared by the tally and the eviction sweep.
public enum StyleRecency {

    /// A contribution's weight halves every thirty days. Long enough that a
    /// steady practice holds its confidence across a quiet fortnight, short
    /// enough that a fortnight of doing something differently is already
    /// winning.
    public static let halfLife: TimeInterval = 60 * 60 * 24 * 30

    /// Below this share of its original weight a contribution stops counting
    /// and is swept. Two half-lives — sixty days — so evidence has to go
    /// genuinely cold before it is let go.
    ///
    /// Safe to be this decisive for one specific reason: the corpus is
    /// re-derivable. A tenet is a projection of files that still exist, so
    /// letting one go forgets a summary and never a fact — editing that file
    /// again rebuilds it. That is what makes "never bloated" affordable.
    public static let decayFloor = 0.25

    /// `2^(-age/halfLife)`, clamped to 0…1.
    ///
    /// A contribution from the future (a clock skew, a restored timestamp)
    /// weighs exactly 1 rather than more — evidence cannot count for more than
    /// itself just because a date is wrong.
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
