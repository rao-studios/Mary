//
//  MaryRuntime+MediaPerception.swift
//  MaryRuntime
//
//  WHAT: Publish `perception.player-transport` from the running declared player.
//  IN:   MediaSurfaceSupport / MediaSurfaceAX (MaryPlugin)
//  OUT:  SchemaSignalRuntime.publishPerception (MaryBrain)
//  PIN:  Join lives here — adapter cannot call Brain without inverting layers.
//        Per-turn, not a poll; schema freshness is four seconds.
//

import Foundation
import MaryPlugin
import MaryBrain
import MaryFoundation
import os

extension MaryRuntime {

    private static let mediaPerceptionLog = Logger(
        subsystem: "nyc.rao.mary", category: "media-perception")

    /// Read the running declared player; record transport. Silent if none.
    static func publishPlayerTransportPerception() {
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

        do {
            try SchemaSignalRuntime.shared.publishPerception(
                schemaID: "perception.player-transport",
                value: envelope,
                // Adapter that declared and read it (`media-surface`).
                adapterID: "media-surface")
        } catch {
            // Authoring mismatch (type / privacy / undeclared) — log, do not swallow.
            mediaPerceptionLog.error(
                "player transport perception rejected: \(String(describing: error), privacy: .public)")
        }
    }
}
