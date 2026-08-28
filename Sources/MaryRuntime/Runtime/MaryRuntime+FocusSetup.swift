//
//  MaryRuntime+FocusSetup.swift
//

import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {
    // MARK: - The focused world, published once

    /// The live focus as ONE value both memory paths read: the archive files
    /// deposits under it, and chat retrieval scopes to it. Installed by
    /// `installBrainConfiguration` from the same `resolveFocus()` the prompt
    /// uses, so the prompt, the archive and retrieval can never name
    /// different documents. Unfocused until then — which is exactly today's
    /// behavior (owner-wide pool, `aggregate: true`), so nothing here depends
    /// on boot order.
    ///
    /// LOCK-GUARDED, not `nonisolated(unsafe)`: this closure is WRITTEN from
    /// the main actor whenever settings change (plugins toggled, projects
    /// edited) and READ from the Seer actors on every request and from the
    /// brain's detached archive. That is an unsynchronized cross-actor
    /// read/write of a reference-counted existential — a real data race, not a
    /// theoretical one. Same pattern as `WorkspaceFocusTracker`'s boxes.
    // Internal for the file split (installed by +BrainInstall) — treat as private.
    static let focusSubjectBox =
        OSAllocatedUnfairLock<@Sendable () -> DepositSubject>(initialState: { .unfocused })

    /// Read the installed resolver and run it. Two steps on purpose: the
    /// closure itself may touch locks (the watcher boxes), so it must NOT run
    /// while `focusSubjectBox` is held.
    static func focusSubject() -> DepositSubject {
        let resolver = focusSubjectBox.withLock { $0 }
        return resolver()
    }

    /// Skill binding name → the world that owns it, published when the roster
    /// is built so Routes can name the world behind an invoked Skill.
    ///
    /// DERIVED FROM THE INSTALLED ROSTER, never from a second table: it is
    /// built in `installBrainConfiguration` from the very `plugins` array the
    /// registry is constructed with, so a disabled plugin is absent from both
    /// or neither. A hand-kept copy of this mapping is exactly the "routing
    /// mirror" — the pane and the prompt disagreeing about the same fact —
    /// that the ambient store was built to abolish.
    // These five boxes are internal for the file split (+BrainInstall writes
    // them; +Stack writes totemArchivingEnabledBox) — treat as private.
    static let skillWorldBox =
        OSAllocatedUnfairLock<[String: AmbientWorld]>(initialState: [:])
    static let applicationProfilesBox =
        OSAllocatedUnfairLock<[ApplicationProfile]>(initialState: [])
    static let nativeApplicationProfilesBox =
        OSAllocatedUnfairLock<[ApplicationProfile]>(initialState: [])
    static let brainConfigurationInstalledBox =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    /// The configured project roots, as `installBrainConfiguration` last saw
    /// them. The unit indexer restores one durable catalogue per project at
    /// stack connect, which happens after configuration is installed — so this
    /// is where that list is available without reaching for a config singleton
    /// the service layer does not have.
    static let projectRootsBox =
        OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let abilityProfileBridgeStarted =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    static let totemArchivingEnabledBox =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    /// The Brain card's choice, as `applyEngine` last applied it.
    ///
    /// HERE FOR THE SAME REASON AS `projectRootsBox` above: the wiring
    /// decisions that depend on it are made from places holding no config —
    /// the sign-in view model most of all — and the service layer has no
    /// config singleton to reach for. `applyEngine` is the only writer, and
    /// it is also the only place the choice is ever acted on.
    ///
    /// `.hosted` initially, matching the config default: before the first
    /// `applyEngine` the honest assumption is the one a fresh install makes.
    static let engineChoiceBox =
        OSAllocatedUnfairLock<LLMEngineChoice>(initialState: .hosted)

    /// Read-only snapshot for the debugger. Empty until the first
    /// `installBrainConfiguration`, which is honest: before that there is no
    /// roster to describe.
    static func skillWorldIndex() -> [String: AmbientWorld] {
        skillWorldBox.withLock { $0 }
    }

    static func applicationProfiles() -> [ApplicationProfile] {
        applicationProfilesBox.withLock { $0 }
    }

    /// Ability imports and Studio saves activate a new immutable registry
    /// without rebuilding the app process. Keep the open application profile
    /// index and its Totem knowledge synchronized with those revisions so a
    /// newly taught application is recognizable on the very next turn.
    // Internal for the file split (called by +BrainInstall) — treat as private.
    static func startAbilityProfileBridge() {
        let shouldStart = abilityProfileBridgeStarted.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        Task {
            for await event in AbilityLibrary.shared.events() {
                guard case .activated(let snapshot) = event else { continue }
                let native = nativeApplicationProfilesBox.withLock { $0 }
                let profiles = native + snapshot.plugins.applicationProfiles
                applicationProfilesBox.withLock { $0 = profiles }
                // The ambient roster rides the SAME event. Without this an
                // imported package routes on the next turn but its reads still
                // reach nobody until relaunch — which is the worse half of the
                // bug, because routing working is exactly what makes the
                // missing evidence look like forgetfulness rather than a gap.
                AmbientApplicationBridge.install(profiles: profiles)
                // THE PROSE SURFACES RIDE THE SAME EVENT, for the same
                // reason as the roster: an imported editor must be readable
                // on the very next turn, not after a relaunch. Leaving this
                // behind would make a newly installed application callable
                // and unreadable, which is the worst of both.
                ProseSurfaceSupport.shared.reconcile(
                    proseSurfaceRegistrations(from: snapshot))
                // The observer re-derives its lanes from the roster that just
                // changed: a package imported mid-session starts polling on
                // its declared cadence, a removed one loses its lane and its
                // perceived facts in the same breath.
                AmbientApplicationObserver.shared.activate()
                if totemArchivingEnabledBox.withLock({ $0 }) {
                }
            }
        }
    }

    /// What retrieval may reach RIGHT NOW. Owner-qualified because group ids
    /// are (one Totem DB holds many owners); the caller hands over the
    /// signed-in owner its request is already carrying.
    static func retrievalScope(ownerID: String) -> RetrievalScope {
        let plan = AmbientContextStore.shared.route()?.gate.memory ?? .personal
        return TotemMemoryTopology.retrievalScope(
            for: plan, subject: focusSubject(), ownerID: ownerID)
    }

}
