//
//  MaryRuntime.swift
//  Mary
//
//  The composition root: the long-lived actors that Granite reducers talk to.
//  Granite services own durable state; these own compute (models, audio).
//
//  THE CORE OF THE SPLIT (phase 3). This file keeps the namespace
//  declaration, the singleton stack, and `routedHeldAmbient`. Everything
//  else lives in the sibling files here in Runtime/, each a pure move
//  unless its banner says otherwise:
//
//    MaryRuntime+TTS.swift          TTS backend boot/apply + the voice-notice
//                                     channel + the coding follow-up bridge
//    MaryRuntime+Focus.swift        the "focused world, published once" boxes
//                                     + the HOISTED resolveFocus(assertedFocus:deps:)
//    MaryRuntime+Prompt.swift       the HOISTED heldContext + the system-prompt
//                                     and seer-instructions assembly bodies
//    MaryRuntime+BrainInstall.swift installBrainConfiguration(...)
//    MaryRuntime+Stack.swift        Seer/Totem stack appliers, pronunciations,
//                                     spoken register, coding-agent provider/models
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

/// Holds the live voice session so Start/Stop reducers share one pipeline.
package actor VoiceSessionBox {
    package init() {}
    /// An identity-bearing ownership claim. Teardown may suspend in several
    /// collaborators, so a bare optional is not enough: a late teardown must
    /// never clear (or otherwise act on) a newer owner's pipeline.
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

    /// Claim the box for a new session. Refused while a pipeline is already
    /// installed: two concurrently-scheduled Starts (the mic button racing a
    /// wake-word handoff) both pass the state guard before either sets the
    /// flag, and the loser must bail with its unstarted pipeline rather than
    /// silently replace the winner's.
    package func install(_ pipeline: VoicePipeline) -> Lease? {
        install(pipeline, teardown: { await pipeline.stop() })
    }

    /// Test seam for making teardown observably slow without teaching
    /// `VoicePipeline` about app-level ownership.
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

    /// Stop the current owner, or only `lease` when supplied. The entry stays
    /// installed until teardown has actually returned: exposing an empty box
    /// first creates an ABA race where session A resumes inside shared speaker
    /// cleanup after session B has already claimed the same collaborators.
    /// Concurrent Stop edges coalesce onto one teardown task.
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

        // Actor reentrancy means another waiter may have completed first.
        // Identity checks make both paths harmless and prevent an old lease
        // from ever releasing a later entry.
        if entry?.lease == held.lease {
            entry = nil
        }
        if stopTask?.lease == held.lease {
            stopTask = nil
        }
    }
}

package enum MaryRuntime {

    /// Freezes the selection side of held prompt context to the route's
    /// request-boundary decision. Watchers remain free to publish newer
    /// attention while a turn is running, but that later selection belongs to
    /// a later turn: it may neither replace the routed referent nor render
    /// beside it. Non-selection facts remain available as ambient context.
    /// With no route, preserve the pre-routing behavior and use the store's
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
    /// THE ONE PLACE the process-wide stores are handed to the brain —
    /// behavior-identical to the old `.shared` defaults, ownership made
    /// explicit and greppable (docs/ownership/STAGE-0-entry-gate.md Step 3).
    /// An uninjected brain (every test) now gets FRESH stores instead.
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
        behavior: BehavioralAssembler(recorder: behavioralStore))

    /// THE PROCESS-WIDE ELEMENT INDEX, WITH ITS VECTORIZER ACTUALLY INSTALLED.
    ///
    /// WHAT THIS FIXES: `AmbientElementIndexStore.installVectorizer` existed,
    /// was documented as "production wiring for `.shared`", and had NO CALL
    /// SITE anywhere in the tree. Every production construction took the
    /// `vectorizer: nil` default, so `queryVector` returned nil and all three
    /// consumers — the reference gate, the address probe, the affordance probe
    /// — ran permanently in the lexical-only fallback each of them documents
    /// as a degraded mode. Their embedding thresholds had never once been
    /// consulted in a shipping build.
    ///
    /// A LET WITH A BODY, not a call in `init`, because the store it wires is
    /// a `static let` too: this is the one evaluation that can be guaranteed
    /// to happen before the brain reads the wiring.
    ///
    /// NIL VECTORIZER IS STILL A VALID WORLD. An OS with no English embedding
    /// asset leaves the store exactly as it is today, which is why the guard
    /// is a `flatMap` rather than a force.
    private static let elementIndex: AmbientElementIndexStore = {
        let store = AmbientElementIndexStore.shared
        if let vectorizer = NLAmbientTextVectorizer.shared {
            store.installVectorizer(vectorizer)
        }
        return store
    }()

    /// WHERE SEALED EPISODES GO, and the setting that governs whether any do.
    ///
    /// The flag is read PER APPEND rather than captured here, so switching
    /// recording off takes effect on the next turn instead of the next launch
    /// — which is what a person expects of a switch.
    package static let behavioralStore = BehavioralStore(
        isEnabled: { behavioralRecordingEnabledBox.withLock { $0 } })

    package static let behavioralRecordingEnabledBox =
        OSAllocatedUnfairLock<Bool>(initialState: true)
    static let voiceSession = VoiceSessionBox()

    /// Admission happens before `VoiceService.Start` is sent to Granite.
    /// Granite's shipping `.streamingTask` behavior treats a second send as a
    /// replacement and cancels the first execution before its reducer guard
    /// can run. Holding this bit for the whole session keeps duplicate UI/wake
    /// edges from ever reaching that replacement boundary.
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

    /// The Debugger pane's eyes: SCK window thumbnails across Spaces. App-
    /// side on purpose — Screen Recording TCC and AppKit stay out of
    /// MaryBrain (WorkspaceFocusObserver's rule). Captures only while the
    /// pane polls.
    package static let captureService = WindowCaptureService()

    // The local Seer/Totem stack: process manager, account session, chat
    // lane, and the totem deposit store. Reconfigured by the appliers below;
    // the instances themselves live for the app (sessions and pid tracking
    // must survive settings changes).
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
    // No session: /v1/totems is on Seer's open router, and the Totems pane
    // must see the fleet before (or without) a sign-in.
    package static let seerTotems = SeerTotemsClient(
        baseURL: URL(string: "http://127.0.0.1:\(ServerSpec.Defaults.seerPort)")!)
    static let totemContext = TotemContextStore(session: seerSession)

    /// The corpus's durable half: one card per indexed unit, plus the
    /// per-project manifest that lets a relaunch resume instead of re-reading
    /// every file.
    ///
    /// Its annotator is installed later, in `applyEngine`, because which one
    /// can answer depends on where the words are going — see
    /// `SeerUnitAnnotator` for why the on-device engine declines.
    static let unitIndexer = AmbientUnitIndexingCoordinator { unit, manifest in
        await totemContext.depositUnitIndex(unit, manifest: manifest)
        // The same settle that produced this unit also moved style tallies.
        // Coalesced, so a two-dozen-file crawl is one write.
        requestStyleProfileSave()
    }

    /// Coalescing slot for the style-profile write.
    static let styleSaveBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
}
