//
//  MaryRuntime+WebPerception.swift
//  MaryRuntime
//
//  WHAT: Publish `perception.page-context` from the browser the person is using.
//  IN:   WebSurfaceSupport / WebSurfaceAX (MaryPlugin)
//  OUT:  SchemaSignalRuntime.publishPerception (MaryBrain)
//  PIN:  ACCESSIBILITY ONLY, EVERY TURN. This reads the browser's own shell — its title
//        and its address field — and never its page. Reading the page means reading
//        pixels, and pixels are read when a Skill asks, never on a turn's own schedule.
//        THE SITE, NOT THE ADDRESS. What reaches the prompt is "youtube", because a URL
//        in a transcript is both unreadable and more than was asked for.
//        Join lives here — the adapter cannot call Brain without inverting layers.
//

import Foundation
import MaryPlugin
import MaryBrain
import MaryFoundation
import os

extension MaryRuntime {

    private static let webPerceptionLog = Logger(
        subsystem: "nyc.rao.mary", category: "web-perception")

    /// Read the browser in use; record which page it is on. Silent if none.
    static func publishPageContextPerception() {
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

        do {
            try SchemaSignalRuntime.shared.publishPerception(
                schemaID: "perception.page-context",
                value: envelope,
                adapterID: "web-surface")
        } catch {
            // Authoring mismatch (type / privacy / undeclared) — log, do not swallow.
            webPerceptionLog.error(
                "page context perception rejected: \(String(describing: error), privacy: .public)")
        }
    }
}
