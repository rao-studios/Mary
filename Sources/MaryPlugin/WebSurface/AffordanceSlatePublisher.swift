//
//  AffordanceSlatePublisher.swift
//  MaryPlugin
//
//  WHAT: A page read, published as what the screen NAMED — offers and candidates alike.
//  IN:   the vision roster  OUT: AmbientElementIndexStore, for PageRouter / AffordanceProbe
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
//        WHAT IT PUBLISHES IS THE PAGE'S RULESET'S BUSINESS. See `PageRowRule`: a row the
//        map named but did not offer is published as a CANDIDATE, so the router can weigh
//        it while `AffordanceProbe` — which acts without asking — still sees only what
//        the reading was sure of.
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
            PageRowRule.records(for: roster.rows, scope: scope), scope: scope)
    }

    /// Nothing is on offer any more.
    public static func retract(
        scope: AmbientElementScope? = nil,
        store: AmbientElementIndexStore = .shared
    ) {
        let scope = scope ?? browserScope
        store.noteElements([], scope: scope)
    }
}
