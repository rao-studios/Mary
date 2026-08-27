//
//  MaryObserver.swift
//  MaryBrain
//
//  The second kind of plugin. Where a MaryAdapter is application-layer —
//  it exposes model-facing Skills that read and modify a Mac app — a
//  MaryObserver helps OTHER plugins: it contributes live, per-turn
//  prompt context and shared services that an application-layer plugin
//  consumes. Support plugins declare no Skills and never appear in the
//  roster; their host plugin owns the Skills.
//
//  The first three support plugins power the Xcode peer-coder: a live-context
//  watcher (what file/selection the user is on), a per-project quirks
//  knowledge base, and a background build verifier.
//

import Foundation

public protocol MaryObserver: Sendable {
    /// Stable id, e.g. "xcode_context", "quirks", "build_verifier".
    var id: String { get }

    /// Evaluated every turn, exactly like the injected clock. Return nil to
    /// contribute nothing — the gate that keeps a prompt lean when this
    /// observer has nothing to say.
    ///
    /// NO CONTEXT PARAMETER. Bonnie passed an `XcodeContext?` here, so every
    /// observer in the system took an argument shaped like one application's
    /// focus — a Notes watcher and a browser watcher both received Xcode's
    /// current source file and ignored it. An observer already holds whatever
    /// it watches; a parameter naming one application is a compiled
    /// application in the contract's clothing.
    ///
    /// Must be synchronous: the brain's prompt provider is a synchronous
    /// `@Sendable () -> String`, so contributions read lock-guarded boxes,
    /// never actors.
    func promptContribution() -> String?

    /// The ambient signals this plugin can normalize for Mary.
    var ambientSenses: Set<AmbientSense> { get }

    /// Stable schema IDs emitted by this support adapter. These are separate
    /// from `ambientSenses`: Xcode selection is a code-selection Interaction,
    /// while ordinary editors publish the shared text-selection Interaction.
    var providedInteractions: Set<InteractionID> { get }
    var providedPerceptions: Set<PerceptionID> { get }

    /// Optional typed inventory for a watcher, sensor, or other non-callable
    /// adapter. Support manifests may publish Interactions and Perceptions
    /// without exposing model-facing operations.
    var adapterManifest: InstalledAdapterManifest? { get }

    /// Refreshes volatile ambient context immediately before a turn.
    func refreshAmbientContext() async

    /// Start background work (polling, verifying). Idempotent.
    func activate() async

    /// Stop background work.
    func deactivate() async
}

public extension MaryObserver {
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
