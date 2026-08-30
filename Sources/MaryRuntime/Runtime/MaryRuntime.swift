//
//  MaryRuntime.swift
//  MaryRuntime
//
//  WHAT: Composition root. Granite reducers talk to these actors.
//  OUT:  VoicePipeline / MaryBrain / Totem via the stack below.
//        Siblings: +TTS, +Focus, +Prompt, +BrainInstall, +Stack.
//  PIN:  Granite owns durable state; these own compute (models, audio).
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

/// Start/Stop reducers share one VoicePipeline.
package actor VoiceSessionBox {
    package init() {}
    /// Ownership token. A late teardown must not clear a newer owner's pipeline.
    package struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
    }

    private struct Entry {
        let lease: Lease
        let pipeline: VoicePipeline
        let teardown: @Sendable () async -> Void
    }

    private var entry: Entry?
    private var stopTask: (lease: Lease, task: Task<Void, Never>)?

    /// Claim the box. Refused if a pipeline is already installed (racing Starts).
    package func install(_ pipeline: VoicePipeline) -> Lease? {
        install(pipeline, teardown: { await pipeline.stop() })
    }

    /// Test seam: slow teardown without teaching VoicePipeline about ownership.
    package func install(
        _ pipeline: VoicePipeline,
        teardown: @escaping @Sendable () async -> Void
    ) -> Lease? {
        guard entry == nil else { return nil }
        let lease = Lease(id: UUID())
        entry = Entry(lease: lease, pipeline: pipeline, teardown: teardown)
        return lease
    }

    package func current() -> VoicePipeline? { entry?.pipeline }

    /// Stop current owner, or only `lease`. Entry stays until teardown returns
    /// (ABA: A must not clear B). Concurrent Stops coalesce.
    package func stop(_ lease: Lease? = nil) async {
        guard let held = entry,
              lease == nil || lease == held.lease
        else { return }

        let task: Task<Void, Never>
        if let stopping = stopTask, stopping.lease == held.lease {
            task = stopping.task
        } else {
            task = Task { await held.teardown() }
            stopTask = (held.lease, task)
        }

        await task.value

        // Reentrancy: another waiter may have finished first. Identity only.
        if entry?.lease == held.lease {
            entry = nil
        }
        if stopTask?.lease == held.lease {
            stopTask = nil
        }
    }
}

package enum MaryRuntime {

    /// Freeze held selection to the route's request-boundary decision.
    /// Later watcher attention belongs to a later turn. No route → store's
    /// current direct attention.
    package static func routedHeldAmbient(
        facts: [AmbientFact],
        attention: AmbientAttention?,
        route: AmbientRoute?
    ) -> (facts: [AmbientFact], attention: AmbientAttention?) {
        guard let route else {
            return (
                facts,
                attention?.isDirectReference == true ? attention : nil)
        }

        return (
            facts.filter(route.admitsHeldFact),
            route.routedSelectionAttention)
    }

    static let kokoro = KokoroEngine()
    static let seerTTS = SeerTTSEngine(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        tokenProvider: { await seerSession.validToken() })
    package static let speaker = KokoroStreamSpeaker(engine: kokoro)
    /// Process-wide stores → brain. Uninjected (tests) get fresh stores.
    package static let brain = MaryBrain(
        engine: MaryLocalEngine(),
        wiring: brainWiring)

    /// The process-wide stores, named once.
    package static let brainWiring = BrainWiring(
        retrieval: .shared,
        containers: .shared,
        focusTracker: .shared,
        readLedger: .shared,
        ambient: .shared,
        elementIndex: elementIndex,
        behavior: BehavioralAssembler(recorder: TotemBehavioralRecording()))

    /// Process-wide element index; installs NLAmbientTextVectorizer when present.
    /// PIN: static-let body so the brain never sees an unwired `.shared`.
    ///      Nil vectorizer (no English embedding asset) is valid.
    private static let elementIndex: AmbientElementIndexStore = {
        let store = AmbientElementIndexStore.shared
        if let vectorizer = NLAmbientTextVectorizer.shared {
            store.installVectorizer(vectorizer)
        }
        return store
    }()

    package static let skillRunTimeoutBox = OSAllocatedUnfairLock<TimeInterval>(
        initialState: AbilityRuntime.ordinarySkillTimeoutDefault)
    package static let abilityDepositNoticeBox =
        OSAllocatedUnfairLock<String?>(initialState: nil)

    package static func applySkillRunTimeout(_ seconds: TimeInterval) {
        let clamped = AbilityRuntime.clampedOrdinarySkillTimeout(seconds)
        skillRunTimeoutBox.withLock { $0 = clamped }
        Task { await brain.setOrdinarySkillTimeout(clamped) }
    }
    static let voiceSession = VoiceSessionBox()

    /// Gate before VoiceService.Start. A second Granite send would cancel the first.
    private static let voiceStartAdmission = OSAllocatedUnfairLock<Bool>(initialState: false)

    package static func admitVoiceStart() -> Bool {
        voiceStartAdmission.withLock { admitted in
            guard !admitted else { return false }
            admitted = true
            return true
        }
    }

    package static func releaseVoiceStart() {
        voiceStartAdmission.withLock { $0 = false }
    }

    /// Debugger SCK thumbnails. App-side (TCC/AppKit stay out of MaryBrain).
    package static let captureService = WindowCaptureService()

    // Local Seer/Totem stack. Instances live for the app; appliers reconfigure.
    package static let localStack = LocalStackManager()
    package static let seerSession = SeerSession(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        email: ServerSpec.Defaults.seerEmail,
        password: ServerSpec.Defaults.seerPassword)
    static let seerChat = SeerChatClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    static let seerRealtime = SeerRealtimeClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    static let seerVision = SeerVisionClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    static let seerComplete = SeerCompleteClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    static let seerSkill = SeerSkillClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    static let seerCode = SeerCodeClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!,
        session: seerSession)
    // No session: /v1/totems is open; Totems pane works before sign-in.
    package static let seerTotems = SeerTotemsClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!)
    static let totemContext = TotemContextStore(session: seerSession)

    /// Corpus durable half (unit cards + resume manifest).
    /// Annotator installed in applyEngine → SeerUnitAnnotator.
    static let unitIndexer = AmbientUnitIndexingCoordinator { unit, manifest in
        await totemContext.depositUnitIndex(unit, manifest: manifest)
        // Same settle also moved style tallies; coalesced write.
        requestStyleProfileSave()
    }

    /// Coalescing slot for the style-profile write.
    static let styleSaveBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
}
