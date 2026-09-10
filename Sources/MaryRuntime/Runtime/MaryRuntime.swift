//
//  MaryRuntime.swift
//  MaryRuntime
//
//  WHAT: Composition root. Granite reducers talk to these actors.
//  OUT:  VoicePipeline / MaryBrain / Thread via the stack below.
//        Siblings: +TTS, +Focus, +Prompt, +BrainInstall, +Stack.
//  PIN:  Granite owns durable state; these own compute (models, audio).
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryThread
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
        world: AmbientWorld.Snapshot?,
        route: AmbientRoute?
    ) -> (facts: [AmbientFact], world: AmbientWorld.Snapshot?) {
        guard let route else {
            return (
                facts,
                world?.isDirectReference == true ? world : nil)
        }

        return (
            facts.filter(route.admitsHeldFact),
            route.routedSelectionWorld)
    }

    static let kokoro = KokoroEngine()
    static let sewnTTS = SewnTTSEngine(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        tokenProvider: { await sewnSession.validToken() })
    package static let speaker = KokoroStreamSpeaker(engine: kokoro)
    /// Process-wide stores → brain. Uninjected (tests) get fresh stores.
    /// Lane B before any applier runs. Sewn-backed from the first instant:
    /// Mary loads no model of her own.
    package static let brain = MaryBrain(
        engine: MarySewnSkillEngine(client: sewnSkill),
        wiring: brainWiring)

    /// The process-wide stores, named once.
    package static let brainWiring = BrainWiring(
        retrieval: .shared,
        containers: .shared,
        focusTracker: .shared,
        readLedger: .shared,
        world: .shared,
        elementIndex: elementIndex,
        behavior: BehavioralAssembler(recorder: ThreadBehavioralRecording()))

    /// Process-wide element index; installs NLAmbientTextVectorizer when present.
    /// PIN: static-let body so the brain never sees an unwired `.shared`.
    ///      Nil vectorizer (no English embedding asset) is valid.
    private static let elementIndex: AmbientElementIndexStore = {
        let store = AmbientElementIndexStore.shared
        if let vectorizer = MaryEmbeddings.vectorizer() {
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

    // Local Sewn/Thread stack. Instances live for the app; appliers reconfigure.
    package static let localStack = LocalStackManager()
    package static let sewnSession = SewnSession(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        email: ServerSpec.Defaults.sewnEmail,
        password: ServerSpec.Defaults.sewnPassword)
    static let sewnChat = SewnChatClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    static let sewnRealtime = SewnRealtimeClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    static let sewnVision = SewnVisionClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    static let sewnComplete = SewnCompleteClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    static let sewnSkill = SewnSkillClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    static let sewnCode = SewnCodeClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    /// Vectors, not generation — the tier under Apple's on-device model.
    /// `MaryEmbeddings` decides whether anything asks it.
    static let sewnEmbedding = SewnEmbeddingClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    /// Which backends Sewn can serve, and warming the on-device one.
    static let sewnProviders = SewnProvidersClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!,
        session: sewnSession)
    // No session: /v1/threads is open; Threads pane works before sign-in.
    package static let sewnThreads = SewnThreadsClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.sewnPort)")!)
    static let threadContext = ThreadContextStore(session: sewnSession)

    /// Corpus durable half (unit cards + resume manifest).
    /// Annotator installed in applyEngine → SewnUnitAnnotator.
    static let unitIndexer = AmbientUnitIndexingCoordinator { unit, manifest in
        await threadContext.depositUnitIndex(unit, manifest: manifest)
        // Same settle also moved style tallies; coalesced write.
        requestStyleProfileSave()
    }

    /// Coalescing slot for the style-profile write.
    static let styleSaveBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
}
