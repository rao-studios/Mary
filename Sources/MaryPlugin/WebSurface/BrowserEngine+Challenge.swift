//
//  BrowserEngine+Challenge.swift
//  MaryPlugin
//
//  WHAT: The human check — a verification interstitial a navigation landed on,
//        given time to clear itself, pressed at most once, then handed back.
//  IN:   PageChallenge (what one looks like, and where its box is)
//  OUT:  satisfyingChallenge / challengeCleared
//  PIN:  PRESSED AT MOST ONCE. The auto-clearing kind runs its own test and
//        moves on; pressing during it is wasted, and pressing is not nothing.
//        A check that does not clear after one press is the person's to finish.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {
    // MARK: - The human check

    /// How long the auto-clearing kind of check gets before anything is pressed.
    /// "Checking your browser…" runs its own test and moves on by itself; reading
    /// the page and pressing during it is wasted, and pressing is not nothing.
    static let challengeGrace: Double = 3
    /// How long a pressed check gets to clear before it is handed back.
    static let challengeBudget: Double = 8

    /// If the navigation landed on a human-verification interstitial, press its
    /// visible control once and look again; otherwise the outcome stands.
    ///
    /// PIN: A NO-OP ON AN ORDINARY PAGE. `PageChallenge.isChallenge` reads the
    /// title the shell already carries, so this touches nothing unless the tab
    /// is literally titled like an interstitial. Then, in order: WAIT, because
    /// the common kind clears itself and pressing during it is pointless; READ
    /// the page from pixels and aim at the box, not the sentence; PRESS ONCE
    /// through the same glide-and-click every page control gets — the real
    /// cursor, which is what a rendered page sees; LOOK AGAIN. If one press did
    /// not clear it, hand it back. Hammering a challenge is the thing this is not.
    func satisfyingChallenge(
        _ settled: BrowserOutcome, in target: BrowserTarget
    ) async -> BrowserOutcome {
        guard settled.ok, let shell = settled.shell,
              PageChallenge.isChallenge(title: shell.title)
        else { return settled }

        emit(.acted("a human-check stands on the page"))
        // THE AUTO-CLEARING KIND, given its moment first.
        if let cleared = await challengeCleared(in: target, within: Self.challengeGrace) {
            return clearedOutcome(cleared, target: target)
        }

        // READ, AND AIM AT THE BOX. The stage is already held — this runs inside
        // the navigation that found the challenge — and `press` asks whether it
        // is still ours; the cursor goes back when that navigation's `staged`
        // ends, never from a deferred Task.
        guard case .success(let roster) = await read(target, shell: shell),
              let aim = PageChallenge.aim(in: roster.rows)
        else {
            // Nothing to press. It may still clear on its own; otherwise it is theirs.
            if let cleared = await challengeCleared(in: target, within: Self.challengeBudget) {
                return clearedOutcome(cleared, target: target)
            }
            return refuse(.humanCheck)
        }

        // PRESS ONCE, THE WAY EVERY PAGE CONTROL IS PRESSED.
        guard await press(at: aim.point, in: target) else {
            return refuse(.interrupted(atCommand: 0))
        }
        emit(.acted("pressed \(aim.named)"))

        // LOOK AGAIN.
        if let cleared = await challengeCleared(in: target, within: Self.challengeBudget) {
            return clearedOutcome(cleared, target: target)
        }
        return refuse(.humanCheck)
    }

    private func clearedOutcome(
        _ cleared: WebSurfaceAX.Reading, target: BrowserTarget
    ) -> BrowserOutcome {
        lastChrome = cleared
        emit(.verified("the human-check cleared"))
        return BrowserOutcome(
            ok: true,
            spoken: Self.spoken(cleared, browser: target.spokenName),
            shell: cleared)
    }

    /// Poll the shell title until it is no longer an interstitial, or the budget
    /// runs out. Returns the cleared reading, or nil if it never cleared.
    func challengeCleared(
        in target: BrowserTarget, within seconds: Double = 8
    ) async -> WebSurfaceAX.Reading? {
        await waitForShell(target, budget: seconds) { !PageChallenge.isChallenge(title: $0.title) }
            .settled
    }
}
