//
//  MaryRuntime+MediaPerception.swift
//  MaryRuntime
//
//  THE FIRST PERCEPTION ANYTHING ACTUALLY PUBLISHES.
//
//  `SchemaSignalRuntime.publishPerception` was written, validated, and had
//  ZERO CALLERS. The consequence was invisible until a package leaned on it:
//  `multimedia.mary` declares `perception.player-transport`, every one of its
//  Skills required it, and the dispatch gate refuses a Skill whose required
//  Perception is not current — so `control_playback` reported
//
//      requires current Perception perception.player-transport
//
//  after passing every readiness check ahead of it. A required Perception
//  nothing can produce is a Skill that installs, validates, routes, offers
//  itself to the model, and then refuses at the last gate.
//
//  WHY THIS LIVES IN MaryRuntime AND NOT BESIDE THE ADAPTER. Reading a
//  player's transport is `MaryPlugin`; recording a Perception is
//  `MaryBrain`; and MaryBrain depends on MaryPlugin, so the adapter cannot
//  call into the signal runtime without inverting the layering. A join
//  between two layers belongs at the composition root that already owns both
//  — the same reasoning that puts the profile and prose-surface bridges here.
//
//  PUBLISHED PER TURN rather than on a background cadence. The Perception's
//  own schema gives it a four-second freshness window, which no poll interval
//  can honour cheaply and every turn honours exactly: the reading is taken
//  immediately before the turn that might use it, or not at all.
//

import Foundation
import MaryPlugin
import MaryBrain
import MaryFoundation
import os

extension MaryRuntime {

    private static let mediaPerceptionLog = Logger(
        subsystem: "nyc.rao.mary", category: "media-perception")

    /// Reads whichever declared player is running and records its transport as
    /// `perception.player-transport`.
    ///
    /// SILENT WHEN THERE IS NOTHING TO SAY, and that is the normal case: no
    /// declared player running, none of them readable, or no Accessibility
    /// grant. A Perception is a claim that Mary CURRENTLY observes something,
    /// so the honest answer to "no player" is to publish nothing and let the
    /// existing value expire on its own schema-owned window.
    static func publishPlayerTransportPerception() {
        guard let (registration, pid) = MediaSurfaceSupport.shared.resolve(nil),
              let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
        else { return }

        // THE SAME SENTENCE `now_playing` ANSWERS WITH. Rendering the reading
        // twice would let the Perception and the Skill that reports it drift,
        // and the drift would be invisible: both would look right in isolation
        // and disagree only about a player neither test happened to run.
        let summary = MediaSurfaceAdapter.spoken(reading, registration: registration)
        let envelope = ValueEnvelope(
            typeID: "multimedia.now-playing-report",
            value: .string(summary),
            // SCOPED TO THE PROCESS THAT WAS READ. The store keys a Perception
            // by schema AND scope, so two declared players running at once
            // hold two readings rather than overwriting one another.
            scope: SourceScope(
                applicationID: registration.applicationID,
                processID: pid),
            provenance: .init(operation: "now_playing"),
            privacy: .private)

        do {
            try SchemaSignalRuntime.shared.publishPerception(
                schemaID: "perception.player-transport",
                value: envelope,
                // UNDER THE ADAPTER THAT DID THE READING, not under a
                // publisher identity of this file's own. `publishPerception`
                // refuses an adapter that does not declare the Perception in
                // its manifest, and `media-surface` is both the thing that
                // declares it and the thing that read it.
                adapterID: "media-surface")
        } catch {
            // NOT FATAL AND NOT SILENT. A rejected publish means the package
            // and the manifest disagree — a wrong Value type, a privacy
            // downgrade, an undeclared Perception — and every one of those is
            // an authoring error that would otherwise present as a Skill
            // mysteriously refusing at dispatch.
            mediaPerceptionLog.error(
                "player transport perception rejected: \(String(describing: error), privacy: .public)")
        }
    }
}
