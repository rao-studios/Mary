//
//  TurnPerceptionPublisher.swift
//  MaryBrain
//
//  WHAT: The declared perceptions a turn publishes before anything is routed — what is
//        playing, and what page a browser is on.
//  IN:   MediaSurfaceSupport / WebSurfaceSupport (MaryPlugin)
//  OUT:  SchemaSignalRuntime.publishPerception
//  PIN:  IN MARYBRAIN BECAUSE SAND CANNOT REACH MARYRUNTIME. These were `static` on
//        MaryRuntime, which the app and the probes link and Sand deliberately does not —
//        it wants the ability graph and the hands, not Granite, Totem or a model. Every
//        call below is a public MaryPlugin or MaryBrain entry point, so they belong
//        beside the runtime that consumes them. Same reasoning as
//        `AbilityRuntime+SurfaceRegistrations`.
//        A BENCH THAT ROUTES WITHOUT THESE IS NOT ROUTING THE SAME TURN. A browsing
//        request arbitrated with no page evidence takes a different path from the one
//        Mary takes, which makes the bench a story rather than a rehearsal.
//        ACCESSIBILITY ONLY, EVERY TURN. Both read a shell — a player's transport, a
//        browser's title and address field — and never a page's contents. Reading a page
//        means reading pixels, and pixels are read when a Skill asks, never on a turn's
//        own schedule.
//        THE SITE, NOT THE ADDRESS. What reaches the prompt is "youtube", because a URL
//        in a transcript is both unreadable and more than was asked for.
//

import Foundation
import MaryFoundation
import MaryPlugin
import os

public enum TurnPerceptionPublisher {

    private static let log = Logger(
        subsystem: "nyc.rao.mary", category: "turn-perception")

    /// Publish everything a turn declares, in one call. What a turn-context preparer
    /// wants; the two halves stay separate for callers that need only one.
    public static func publishAll() {
        publishPlayerTransport()
        publishPageContext()
    }

    /// Read the running declared player; record transport. Silent if none.
    public static func publishPlayerTransport() {
        guard let (registration, pid) = MediaSurfaceSupport.shared.resolve(nil),
              let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
        else { return }

        // Same sentence `now_playing` answers with — Perception and Skill must not drift.
        let summary = MediaSurfaceAdapter.spoken(reading, registration: registration)
        let envelope = ValueEnvelope(
            typeID: "multimedia.now-playing-report",
            value: .string(summary),
            // Scope = process read. Two players hold two readings.
            scope: SourceScope(
                applicationID: registration.applicationID,
                processID: pid),
            provenance: .init(operation: "now_playing"),
            privacy: .private)

        publish(
            envelope, as: "perception.player-transport",
            // Adapter that declared and read it (`media-surface`).
            adapterID: "media-surface", what: "player transport")
    }

    /// Read the browser in use; record which page it is on. Silent if none.
    public static func publishPageContext() {
        guard let (registration, pid) = WebSurfaceSupport.shared.resolve(nil),
              let reading = WebSurfaceAX.read(pid: pid, registration: registration)
        else { return }

        // The same sentence `current_page` answers with — Perception and Skill must not
        // drift, or the prompt line and the spoken answer describe different pages.
        let summary = BrowserEngine.spoken(reading, browser: registration.displayName)
        let envelope = ValueEnvelope(
            typeID: "browsing.page-report",
            value: .string(summary),
            // Scope = process read. Two browsers hold two readings.
            scope: SourceScope(
                applicationID: registration.applicationID,
                processID: pid),
            provenance: .init(operation: "current_page"),
            privacy: .private)

        publish(
            envelope, as: "perception.page-context",
            adapterID: "web-surface", what: "page context")
    }

    /// One publish, one refusal shape.
    ///
    /// An authoring mismatch (wrong type, wrong privacy, undeclared perception) is
    /// logged rather than swallowed: it means a package and its adapter disagree, which
    /// is a thing to fix and not a thing to survive quietly.
    private static func publish(
        _ envelope: ValueEnvelope, as schemaID: PerceptionID,
        adapterID: AdapterID, what: String
    ) {
        do {
            try SchemaSignalRuntime.shared.publishPerception(
                schemaID: schemaID, value: envelope, adapterID: adapterID)
        } catch {
            log.error(
                "\(what, privacy: .public) perception rejected: \(String(describing: error), privacy: .public)")
        }
    }
}
