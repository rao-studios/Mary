//
//  TurnPerceptionPublisher.swift
//  MaryBrain
//
//  WHAT: The declared perceptions a turn publishes before anything is routed.
//  IN:   whatever adapters declare `turnPerceptions()`
//  OUT:  SchemaSignalRuntime.publishPerception
//  PIN:  IT ASKS; IT DOES NOT KNOW. This file used to hold two hard-coded
//        readers naming `MediaSurfaceSupport`, `MediaSurfaceAX`,
//        `WebSurfaceSupport`, `WebSurfaceAX`, `BrowserEngine` and four literal
//        schema ids — so MaryBrain knew what a browser and a music player were,
//        and a third surface could not publish a perception without editing the
//        brain. An adapter states what it perceives; this collects.
//        IN MARYBRAIN BECAUSE SAND CANNOT REACH MARYRUNTIME. Sand wants the
//        ability graph and the hands, not Granite, Thread or a model, so the
//        collector lives beside the runtime that consumes it — the same
//        reasoning as `AbilityRuntime+SurfaceRegistrations`.
//        A BENCH THAT ROUTES WITHOUT THESE IS NOT ROUTING THE SAME TURN. A
//        browsing request arbitrated with no page evidence takes a different
//        path from the one Mary takes, which makes the bench a story rather
//        than a rehearsal.
//        THE ADAPTER IT ASKED IS THE ADAPTER IT STAMPS, so a perception can
//        never be attributed to a provider that did not produce it.
//

import Foundation
import MaryFoundation
import MaryPlugin
import os

public enum TurnPerceptionPublisher {

    private static let log = Logger(
        subsystem: "nyc.rao.mary", category: "turn-perception")

    /// Publish everything the installed adapters declare, in one call.
    ///
    /// Sequential rather than concurrent on purpose: each reader is a bounded
    /// Accessibility read of one shell, they run on every turn, and a burst of
    /// parallel AX walks is exactly the cost this layer is careful about.
    public static func publishAll(
        adapters: [any MaryAdapter] = MaryAdapterCatalog.adapters()
    ) async {
        for adapter in adapters {
            let declared = await adapter.turnPerceptions()
            guard !declared.isEmpty else { continue }
            let adapterID = AdapterID.normalized(adapter.name)
            for perception in declared {
                publish(
                    perception.value, as: perception.schemaID,
                    adapterID: adapterID, what: perception.schemaID.rawValue)
            }
        }
    }

    /// One publish, one refusal shape.
    ///
    /// An authoring mismatch (wrong type, wrong privacy, undeclared perception)
    /// is logged rather than swallowed: it means a package and its adapter
    /// disagree, which is a thing to fix and not a thing to survive quietly.
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
