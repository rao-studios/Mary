//
//  MaryObserver.swift
//  MaryBrain
//
//  WHAT: Support plugin — live prompt context and shared services.
//  IN:   MaryAdapterCatalog.observers / host plugin
//  OUT:  promptContribution / ambientLine / AmbientContextStore
//  PIN:  No Skills, never in the roster. Host plugin owns the Skills.
//

import Foundation

public protocol MaryObserver: Sendable {
    /// Stable id, e.g. "xcode_context", "quirks", "build_verifier".
    var id: String { get }

    /// Per-turn prompt fragment. Nil = contribute nothing.
    /// PIN: no context parameter — observer already holds what it watches.
    ///      Synchronous: brain prompt provider is `@Sendable () -> String`.
    func promptContribution() -> String?

    /// Where this observer looks. Nil = faculty serving every place.
    /// OUT: WorkspaceFocusArbiter
    var observedPlace: AmbientPlace? { get }

    /// One-line version when this observer's place did not lead.
    /// PIN: demotion is volume, not erasure. Nil = nothing to say.
    var ambientLine: String? { get }

    /// Whole document vs a window onto part of it. Channel property, not app.
    var holdsWholeDocument: Bool { get }

    /// Ambient signals this plugin can normalize.
    var ambientSenses: Set<AmbientSense> { get }

    /// Schema IDs this support adapter emits. Separate from `ambientSenses`.
    var providedInteractions: Set<InteractionID> { get }
    var providedPerceptions: Set<PerceptionID> { get }

    /// Typed inventory for a watcher/sensor. May publish without model-facing ops.
    var adapterManifest: InstalledAdapterManifest? { get }

    /// Refresh volatile ambient context immediately before a turn.
    func refreshAmbientContext() async

    /// Start background work (polling, verifying). Idempotent.
    func activate() async

    /// Stop background work.
    func deactivate() async
}

public extension MaryObserver {
    /// Infrastructure default: arbiter leaves it out of the weighing.
    var observedPlace: AmbientPlace? { nil }
    var ambientLine: String? { nil }
    /// Cautious default: claiming less sight costs a re-read, not a wrong answer.
    var holdsWholeDocument: Bool { false }
    var ambientSenses: Set<AmbientSense> { [] }
    var providedInteractions: Set<InteractionID> {
        var interactions: Set<InteractionID> = []
        for sense in ambientSenses {
            if sense == .selection { interactions.insert(.textSelection) }
        }
        return interactions
    }
    var providedPerceptions: Set<PerceptionID> {
        var perceptions: Set<PerceptionID> = []
        for sense in ambientSenses {
            if sense == .workspace { perceptions.insert(.workspaceFocus) }
            if sense == .hover { perceptions.insert(.hover) }
        }
        return perceptions
    }
    var adapterManifest: InstalledAdapterManifest? {
        guard !providedInteractions.isEmpty || !providedPerceptions.isEmpty else { return nil }
        let adapterID = AdapterID.normalized(id)
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: id.replacingOccurrences(of: "_", with: " ").capitalized,
            transport: .native,
            providesInteractions: providedInteractions.sorted { $0.rawValue < $1.rawValue },
            providesPerceptions: providedPerceptions.sorted { $0.rawValue < $1.rawValue })
    }
    func refreshAmbientContext() async {}
}
