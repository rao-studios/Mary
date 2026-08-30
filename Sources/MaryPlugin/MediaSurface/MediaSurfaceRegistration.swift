//
//  MediaSurfaceRegistration.swift
//  MaryPlugin
//
//  WHAT: One app's declared transport coordinates, identity attached.
//  IN:   PluginMediaSurfaceSchema  OUT: MediaSurfaceSupport

import Foundation
import MaryAmbient
import MaryFoundation

public struct MediaSurfaceRegistration: Sendable, Equatable, SurfaceClaim {

    /// The package's logical id for the application — the same id its place
    /// is spelled with.
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginMediaSurfaceSchema

    /// The process FAMILY, when the package declared one. Same field, same reason as
    /// `ApplicationRegistration.bundleIdentifierPrefix`: `bundleIdentifiers` is exact and
    /// stays the authority for launching, but membership.
    public let bundleIdentifierPrefix: String?

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        bundleIdentifierPrefix: String? = nil,
        displayName: String,
        schema: PluginMediaSurfaceSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.displayName = displayName
        self.schema = schema
    }

    /// EXACT FIRST, THEN THE FAMILY — the same two-tier question
    /// `ApplicationRegistration.owns(bundleID:)` answers.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }

    /// What the user calls one item here — "track", "episode".
    public var noun: String { schema.itemNoun }

    // MARK: - Label matching

    /// LABELS ARE COMPARED CASE- AND WHITESPACE-INSENSITIVELY, folded once here so the walk
    /// does not re-derive it per node.
    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func isPlayingLabel(_ label: String) -> Bool {
        Self.folded(label) == Self.folded(schema.playingLabel)
    }

    public func isPausedLabel(_ label: String) -> Bool {
        Self.folded(label) == Self.folded(schema.pausedLabel)
    }

    /// Whether this label says shuffle is on. Nil when the label is neither
    /// of the declared words — which is a READ THAT FAILED, not an "off", and
    /// the caller reports it as unknown rather than guessing.
    public func shuffleState(_ label: String) -> Bool? {
        toggleState(label, labels: schema.shuffle, byPrefix: false)
    }

    /// Whether this label says repeat is on. BY PREFIX, because a player distinguishes
    /// modes it cannot express in two words: "repeat one" and "repeat all" are both repeat
    /// being on, and both begin with the word the package declared.
    public func repeatState(_ label: String) -> Bool? {
        toggleState(label, labels: schema.repeatMode, byPrefix: true)
    }

    private func toggleState(
        _ label: String, labels: PluginMediaToggleLabels?, byPrefix: Bool
    ) -> Bool? {
        guard let labels else { return nil }
        let seen = Self.folded(label)
        let off = Self.folded(labels.off)
        let on = Self.folded(labels.on)
        // OFF IS TESTED FIRST, and the order is load-bearing wherever the off
        // word CONTAINS the on word — "do not shuffle" contains "shuffle".
        // Testing on-first would read every off state as on.
        if seen == off || (byPrefix && seen.hasPrefix(off)) { return false }
        if seen == on || (byPrefix && seen.hasPrefix(on)) { return true }
        return nil
    }
}
