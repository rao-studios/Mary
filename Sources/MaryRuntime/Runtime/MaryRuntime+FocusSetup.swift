//
//  MaryRuntime+FocusSetup.swift
//  MaryRuntime
//
//  WHAT: Shared boxes the split files read — focus, roster, engine choice.
//  IN:   +BrainInstall writes; +Stack writes totemArchivingEnabledBox
//  OUT:  resolveFocus / applyEngine / unit indexer / retrievalScope
//  PIN:  Lock-guarded (cross-actor). internal for file split — treat as private.
//

import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import MaryFoundation
import MaryAmbient
import Foundation
import os

extension MaryRuntime {
    // MARK: - The focused world, published once

    /// Live focus both memory paths read (archive filing + chat retrieval).
    /// Installed from the same resolveFocus() the prompt uses.
    // internal for file split — treat as private
    static let focusSubjectBox =
        OSAllocatedUnfairLock<@Sendable () -> DepositSubject>(initialState: { .unfocused })

    /// Read the installed resolver and run it. Closure may touch watcher locks —
    /// must not run while focusSubjectBox is held.
    static func focusSubject() -> DepositSubject {
        let resolver = focusSubjectBox.withLock { $0 }
        return resolver()
    }

    /// Skill binding name → owning world. Built from the installed roster, not a second table.
    // internal for file split — treat as private
    static let skillWorldBox =
        OSAllocatedUnfairLock<[String: AmbientAttention]>(initialState: [:])
    static let applicationProfilesBox =
        OSAllocatedUnfairLock<[ApplicationProfile]>(initialState: [])
    static let nativeApplicationProfilesBox =
        OSAllocatedUnfairLock<[ApplicationProfile]>(initialState: [])
    static let brainConfigurationInstalledBox =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Project roots as installBrainConfiguration last saw them. Unit indexer
    /// restores catalogues at stack connect — after configuration is installed.
    static let projectRootsBox =
        OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let abilityProfileBridgeStarted =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    static let totemArchivingEnabledBox =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Brain card choice as applyEngine last applied. Service layer has no config singleton.
    /// `.hosted` initially, matching the config default.
    static let engineChoiceBox =
        OSAllocatedUnfairLock<LLMEngineChoice>(initialState: .hosted)
    /// Lane B. `.local` initially — acting stayed on-device when speech went to Seer.
    static let skillEngineChoiceBox =
        OSAllocatedUnfairLock<LLMEngineChoice>(initialState: .local)
    static let localModelIDBox =
        OSAllocatedUnfairLock<String>(initialState: MaryLocalEngine.defaultModelID)
    static let codingEngineChoiceBox =
        OSAllocatedUnfairLock<LLMEngineChoice>(initialState: .local)
    static let codingEnabledBox =
        OSAllocatedUnfairLock<Bool>(initialState: false)
    static let seerStackEnabledBox =
        OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Debugger snapshot. Empty until first installBrainConfiguration.
    static func skillWorldIndex() -> [String: AmbientAttention] {
        skillWorldBox.withLock { $0 }
    }

    static func applicationProfiles() -> [ApplicationProfile] {
        applicationProfilesBox.withLock { $0 }
    }

    /// Ability import / Studio save → new registry. Keep profile index + Totem in step.
    // internal for file split — treat as private
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
                // Ambient roster, prose, code, observer — same event so next turn sees them.
                AmbientApplicationBridge.install(profiles: profiles)
                ProseSurfaceSupport.shared.reconcile(
                    snapshot.proseSurfaceRegistrations())
                CodeSurfaceSupport.shared.reconcile(
                    snapshot.codeSurfaceRegistrations())
                AmbientApplicationObserver.shared.activate()
            }
        }
    }

    /// What Seer may retrieve now — Personal + memory/resonance, plus the
    /// focused project's own group when one is in view. Ability codec stays off.
    static func retrievalScope(ownerID: String) -> RetrievalScope {
        TotemMemoryTopology.seerPersonalScope(subject: focusSubject(), ownerID: ownerID)
    }
}
