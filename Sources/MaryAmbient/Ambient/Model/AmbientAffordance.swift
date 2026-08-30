//
//  AmbientAffordance.swift
//  MaryAmbient
//
//  WHAT: Something the screen is offering right now. Neutral — no AX types.
//  IN:   MaryAdapter AX walk
//  OUT:  AffordanceProbe / AmbientElementScope.affordances(in:)
//  PIN:  Not a PageElement (live AXUIElement goes stale). id is the re-find key.
//        frame is capture-stamped evidence, never a click target.
//
import Foundation

/// One actionable thing on screen, as ambient memory holds it.
public struct AmbientAffordance: Sendable, Equatable, Identifiable {

    /// Stable within one publish — the publisher's own handle, used to
    /// re-find the element before acting. Never spoken.
    public var id: String
    /// What the thing calls itself, in its own words: "Skip Ads", "Full screen (f)", "Sign in".
    /// This is the whole reason a goal can reach it — the embedding matches "skip the ad"
    /// against these words, not against a table Mary wrote.
    public var label: String
    /// The humanized role: "button", "link", "field", "video". Lowercased,
    /// and the word a person would actually say.
    public var roleWord: String
    /// Reading-order position among the publisher's affordances, 1-based —
    /// what "the third one" counts.
    public var ordinal: Int
    /// Whether it can be acted on at this instant. A disabled control is
    /// still perceived (so "why can't I press Continue" has an answer) but
    /// resolution will not offer it.
    public var isEnabled: Bool
    /// The control's own help text, when it has one. Frequently the only
    /// place a terse label explains itself.
    public var help: String?
    /// Where it was at publish time — evidence, never a click target. Nil when the producer had
    /// no geometry (a synthesized or scripted affordance).
    public var frame: AXFrame?

    public init(
        id: String,
        label: String,
        roleWord: String,
        ordinal: Int,
        isEnabled: Bool = true,
        help: String? = nil,
        frame: AXFrame? = nil
    ) {
        self.id = id
        self.label = label
        self.roleWord = roleWord
        self.ordinal = ordinal
        self.isEnabled = isEnabled
        self.help = help
        self.frame = frame
    }
}

extension AmbientElementScope {

    /// THE AFFORDANCE PARTITION, and the reason `.pressable` is safe to add. Affordances live
    /// in their own key beside the place's other slates.
    public static func affordances(in place: AmbientPlace) -> AmbientElementScope {
        AmbientElementScope(
            place: place, key: "\(place.token)\(affordanceSuffix)")
    }

    /// How `AffordanceProbe` recognizes one of these partitions among all the slates the index
    /// holds.
    public static let affordanceSuffix = ":affordances"
}
