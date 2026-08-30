//
//  WorkspaceApplicationIdentity.swift
//  MaryAmbient
//
//  WHAT: Bundle identities and sampling cadence for worlds this layer already names.
//  OUT:  adapters read these back. AmbientFact freshness. PinnedWorld.from(bundleID:)
//  PIN:  Vocabulary owns identity; adapters do not. Scrivener is prefix, not equality.
//
import Foundation

/// Exact process identities for the worlds the ambient model names. EXACT, and therefore
/// only for the three worlds whose identifier really is a single fixed string.
public enum WorkspaceApplicationIdentity {
    public static let xcode = "com.apple.dt.Xcode"
    public static let pages = "com.apple.iWork.Pages"
    public static let textEdit = "com.apple.TextEdit"
    public static let keynote = "com.apple.iWork.Keynote"

    /// THE ONE COMPILED BROWSER, and the only browser bundle this layer knows by heart.
    /// `AmbientWorld` carries a closed `.safari` case for it, so it is vocabulary in exactly
    /// the way the other four above are. EVERY OTHER BROWSER IS DISCOVERED, not listed.
    public static let safari = "com.apple.Safari"
}

/// How often a live document surface is sampled.
public enum AmbientSamplingCadence {
    /// The active polling interval for a focused document surface.
    public static let activeInterval: TimeInterval = 2.5

    /// How many active ticks pass between full body refreshes.
    public static let bodyRefreshTicks = 8

    /// How long a cached body remains fresh enough to answer from.
    public static let bodyFreshWindow: TimeInterval =
        activeInterval * Double(bodyRefreshTicks) * 1.5
}
