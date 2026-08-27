//
//  WorkspaceApplicationIdentity.swift
//
//  The bundle identities and sampling cadence of the worlds this layer already
//  names, declared HERE rather than borrowed from whichever adapter happens to
//  implement one.
//
//  WHY THIS FILE EXISTS. `AmbientWorld` and `WritingApp` are closed
//  enumerations owned by this layer — the ambient model already asserts that
//  there is a coding world and three writing worlds. What it was doing before
//  was reaching into the Xcode, Typer, and TextEdit adapters to learn the
//  bundle identifiers for worlds it had itself declared. That is the wrong
//  direction: the layer that owns the vocabulary should own the identity, and
//  the adapter that implements a world should read it back.
//
//  So these are not "constants that used to live somewhere else." They are the
//  identity half of the same closed vocabulary, finally sitting next to it —
//  which is what lets this package build against MaryFoundation alone.
//
//  A host with different worlds replaces this file, or supplies its own
//  registry; nothing below it needs to change.
//

import Foundation

/// Exact process identities for the worlds the ambient model names.
///
/// EXACT, and therefore only for the three worlds whose identifier really is a
/// single fixed string.
///
/// SCRIVENER IS DELIBERATELY ABSENT. Its bundle identifier carries the major
/// version — `com.literatureandlatte.scrivener3`, and `…scrivener4` after it —
/// so membership is a PREFIX test, not an equality test. That predicate already
/// exists, once, as `WorkspaceFocusTracker.scrivenerBundlePrefix`, and the
/// codebase treats it as the one place the question is answered. An exact
/// `scrivener3` constant here would read like a peer of the three below and
/// quietly disagree with it on every future release, which is worse than not
/// offering the constant at all.
///
/// For the same reason there is no `writingApp(forBundleID:)` or
/// `isCoding(bundleID:)` here: a lookup that switched over these constants
/// would inherit the exact-match assumption and be wrong for Scrivener.
/// `PinnedWorld.from(bundleID:)` in `WorkspaceFocusTracker` already answers
/// that question, using equality for these three and the prefix for Scrivener —
/// which is exactly the asymmetry a uniform table here would erase.
public enum WorkspaceApplicationIdentity {
    public static let xcode = "com.apple.dt.Xcode"
    public static let pages = "com.apple.iWork.Pages"
    public static let textEdit = "com.apple.TextEdit"
    public static let keynote = "com.apple.iWork.Keynote"

    /// THE ONE COMPILED BROWSER, and the only browser bundle this layer knows
    /// by heart. `AmbientWorld` carries a closed `.safari` case for it, so it
    /// is vocabulary in exactly the way the other four above are.
    ///
    /// EVERY OTHER BROWSER IS DISCOVERED, not listed. Chrome reaches Mary
    /// as `chrome.mary` — a Dynamic package that declares its own bundle
    /// identifiers and realizes the `browsing` Ability — so writing "Chrome"
    /// into a table here would restate what the package already says, and
    /// would leave the next browser package (Arc, Firefox, a fork) invisible
    /// to the focus ledger no matter what it declared. See
    /// `AmbientPlaceResolver.browserIdentities`.
    public static let safari = "com.apple.Safari"
}

/// How often a live document surface is sampled, and how long a body read
/// stays trustworthy afterwards.
///
/// These bound `AmbientFact` freshness, so they belong to the evidence layer
/// rather than to the watcher that happens to poll on them. The Pages watcher
/// reads its timer cadence back from here.
public enum AmbientSamplingCadence {
    /// The active polling interval for a focused document surface.
    public static let activeInterval: TimeInterval = 2.5

    /// How many active ticks pass between full body refreshes.
    public static let bodyRefreshTicks = 8

    /// How long a cached body remains fresh enough to answer from.
    public static let bodyFreshWindow: TimeInterval =
        activeInterval * Double(bodyRefreshTicks) * 1.5
}
