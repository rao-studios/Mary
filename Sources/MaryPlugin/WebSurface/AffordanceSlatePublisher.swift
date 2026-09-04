//
//  AffordanceSlatePublisher.swift
//  MaryPlugin
//
//  WHAT: A page read, published as what the screen is offering.
//  IN:   the vision roster  OUT: AmbientElementIndexStore, for AffordanceProbe
//  PIN:  PUBLISHED BY A SKILL'S OWN READ, NEVER BY A POLL. Pixels are read when a skill
//        asks and at no other time, so the browser's slate exists exactly as long as a
//        page read is recent — which is why the ambient observer still retracts for
//        browsers and this does the publishing instead.
//        RETRACTED THE MOMENT THE PAGE CHANGES. A slate lives ninety seconds by the
//        probe's reckoning, and a navigation makes every row in it wrong; offering
//        yesterday's buttons is worse than offering none.
//        THE SAME SLATE EVERY OTHER SURFACE PUBLISHES. This is what lets "skip the ad"
//        reach a page through `AffordanceProbe` exactly as it reaches a native window —
//        no browser-shaped path, no second ladder.
//

import Foundation
import MaryAmbient
import MaryComputerUse

public enum AffordanceSlatePublisher {

    /// The scope a browser's offerings live in.
    public static var browserScope: AmbientElementScope {
        AmbientElementScope.affordances(in: AmbientPlaceResolver.browserPlace)
    }

    /// One reading, as the screen's current offerings.
    public static func publish(
        _ roster: PageRoster,
        scope: AmbientElementScope? = nil,
        store: AmbientElementIndexStore = .shared
    ) {
        let scope = scope ?? browserScope
        store.noteElements(
            AffordanceRule.records(for: affordances(from: roster), scope: scope),
            scope: scope)
    }

    /// Nothing is on offer any more.
    public static func retract(
        scope: AmbientElementScope? = nil,
        store: AmbientElementIndexStore = .shared
    ) {
        let scope = scope ?? browserScope
        store.noteElements([], scope: scope)
    }

    /// Rows as affordances. Only what can be acted on, and only what has a name
    /// somebody wrote — a synthesized "button 4" is a position, and a goal that landed
    /// on it would be landing on a guess.
    public static func affordances(from roster: PageRoster) -> [AmbientAffordance] {
        roster.actionable.enumerated().compactMap { index, element in
            guard roster.annotation(for: element)?.labelSource.isReal != false else { return nil }
            return AmbientAffordance(
                id: identity(of: element),
                label: element.label,
                roleWord: element.spokenKind?.spokenWord ?? "button",
                ordinal: index + 1,
                isEnabled: element.isEnabled,
                help: element.containerTrail.first,
                frame: nil)
        }
    }

    /// The key a row keeps across a publish and a lookup — its role and its name, never
    /// its ordinal, which is a position and re-flows on every read.
    public static func identity(of element: AXScreenElement) -> String {
        "\(element.role.lowercased())|\(SpokenReference.normalized(element.label))"
    }
}
