//
//  MediaSurfaceRegistration.swift
//  MaryPlugin
//
//  ONE APPLICATION'S DECLARED TRANSPORT COORDINATES, resolved for use.
//
//  `ProseSurfaceRegistration`'s sibling, and deliberately its twin in shape:
//  a package writes a `mediaSurface` block, the compiler pairs it with the
//  application's identity, and everything the compiled lane needs to read
//  that player is in this value — while nothing in the lane names the player.
//
//  WHY A SEPARATE TYPE FROM THE SCHEMA, unchanged from the prose lane's
//  reasoning: the schema is what an author writes and a validator admits;
//  this is what the runtime uses, with identity attached and the label
//  comparisons already folded to their matching form. A schema change cannot
//  silently alter runtime behaviour, and the mapping is one place with a test.
//

import Foundation
import MaryFoundation

public struct MediaSurfaceRegistration: Sendable, Equatable {

    /// The package's logical id for the application — the same id its place
    /// is spelled with.
    public let applicationID: String

    /// The bundle identifiers this application answers to.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginMediaSurfaceSchema

    /// The process FAMILY, when the package declared one. Same field,
    /// same reason as `ApplicationRegistration.bundleIdentifierPrefix`:
    /// `bundleIdentifiers` is exact and stays the authority for launching,
    /// but membership — "is the running player one of this package's?" — is
    /// a prefix question for any vendor who ships `…player3` and then
    /// `…player4`. Absent means the exact identifiers are the whole answer.
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
    /// `ApplicationRegistration.owns(bundleID:)` answers for ambient routing
    /// and `TypingSurface.isRunning` answers for the taught-writing-surface
    /// rung (`[Corpus P]`), asked here through the identical boundary
    /// predicate, `ApplicationRegistration.isInFamily`. This registration
    /// used to compare only the exact declared id — the same latent shape
    /// `[Corpus P]` fixed elsewhere and noted, but deliberately left
    /// unchanged, here (no currently-taught media application declares a
    /// versioned bundle id, so nothing live broke) — closed now rather than
    /// waiting for a fourth incident.
    public func owns(bundleID: String) -> Bool {
        let lowered = bundleID.lowercased()
        if bundleIdentifiers.contains(where: { $0.lowercased() == lowered }) {
            return true
        }
        guard let prefix = bundleIdentifierPrefix?.lowercased(), !prefix.isEmpty
        else { return false }
        return ApplicationRegistration.isInFamily(lowered, prefix: prefix)
    }

    /// What the user calls one item here — "track", "episode".
    public var noun: String { schema.itemNoun }

    // MARK: - Label matching

    /// LABELS ARE COMPARED CASE- AND WHITESPACE-INSENSITIVELY, folded once
    /// here so the walk does not re-derive it per node.
    ///
    /// The tolerance is not politeness. A transport label is authored by the
    /// application and read through Accessibility, and the two ends disagree
    /// about capitalization more often than not — Apple Music publishes
    /// "do not shuffle" in lower case beside "Pause" in title case, in the
    /// same eight-button bar. A package author reading the bar with a probe
    /// writes down what they see; a package that only matched exact bytes
    /// would fail on whichever of those two they guessed wrong.
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

    /// Whether this label says repeat is on.
    ///
    /// BY PREFIX, because a player distinguishes modes it cannot express in
    /// two words: "repeat one" and "repeat all" are both repeat being on, and
    /// both begin with the word the package declared. Matched the other way
    /// round — declared word as the prefix of the label — so declaring
    /// "repeat" admits both and declaring "repeat one" admits only that.
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
