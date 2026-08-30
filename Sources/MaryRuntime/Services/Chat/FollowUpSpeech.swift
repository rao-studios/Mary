//
//  FollowUpSpeech.swift
//  MaryRuntime
//
//  WHAT: Text-mode follow-up floor — twin of VoicePipeline's origin gate.
//  IN:   origin, current turn, quiet, waited → FollowUpFloor.verdict
//  OUT:  FollowUpSpeech actor serializes delivery to the speaker
//  PIN:  Late follow-up never cuts in. Stale + busy → wait; budget gone → drop.
//        Transcript still shows it under its own exchange.
//

import MaryAmbient
import MaryBrain
import MaryVoice
import Foundation
import os

/// Pure floor rule. Mirrors VoicePipeline.isStaleFollowUpOrigin + playFollowUpWhenQuiet.
package enum FollowUpFloor {

    package enum Verdict: Equatable {
        /// The floor is this follow-up's to take (cutting in if need be).
        case speakNow
        /// Stale and the room is busy — hold, and ask again shortly.
        case waitForQuiet
        /// Stale, still busy, and out of budget. The moment has passed.
        case drop
    }

    /// Quiet budget for a stale follow-up. Matches VoicePipeline (15 s).
    static let quietBudget: TimeInterval = 15

    /// Origin no longer on screen? Nil origin (standalone notice) is never stale.
    package static func isStale(origin: UUID?, currentTurn: UUID?) -> Bool {
        guard let origin, let currentTurn else { return false }
        return origin != currentTurn
    }

    /// May this follow-up softStop current speech? Only if origin is still on screen.
    package static func mayCutIn(origin: UUID?, currentTurn: UUID?) -> Bool {
        !isStale(origin: origin, currentTurn: currentTurn)
    }

    package static func verdict(
        origin: UUID?,
        currentTurn: UUID?,
        roomIsQuiet: Bool,
        waited: TimeInterval,
        budget: TimeInterval = FollowUpFloor.quietBudget
    ) -> Verdict {
        // Quiet is quiet — stale narration may speak when nothing is playing.
        if roomIsQuiet { return .speakNow }
        if !isStale(origin: origin, currentTurn: currentTurn) { return .speakNow }
        return waited >= budget ? .drop : .waitForQuiet
    }
}

/// The hooks the actor needs from the world, injected so the whole policy —
/// including "a stale follow-up never calls softStop" — is testable without a
/// speaker or a live brain.
package struct FollowUpFloorHooks: Sendable {
    /// Is the room quiet? Text mode's answer: nothing speaking and no turn
    /// generating.
    package var roomIsQuiet: @Sendable () async -> Bool
    /// A live voice session owns the speaker (the single-driver rule) — the
    /// pipeline plays its own follow-ups.
    package var voiceOwnsFloor: @Sendable () async -> Bool
    /// Claim the speaker's generation. hardStop only for a new user turn.
    package var claimTextFloor: @Sendable (UUID, Bool) async -> Bool
    /// Detached follow-up may only replace the writer it observed (or idle after).
    package var replaceTextFloor: @Sendable (UUID, UUID?) async -> Bool
    /// `handoff` distinguishes a new detached writer from a same-turn
    /// retraction. A quiet cross-writer handoff invalidates a pending old
    /// synthesis tail; a same-turn correction preserves its takeover hold.
    package var softStop: @Sendable (UUID, Bool) async -> Bool
    /// Keep feed and flush separate and make both conditional at the speaker
    /// actor. A caller-side lease check cannot protect the gap between this
    /// actor and the shared speaker.
    package var feed: @Sendable (String, UUID) async -> Bool
    package var flush: @Sendable (UUID) async -> Bool
    package var record: @Sendable (ReadDelivery) -> Void
    package var sleep: @Sendable (TimeInterval) async -> Void

    package init(
        roomIsQuiet: @escaping @Sendable () async -> Bool,
        voiceOwnsFloor: @escaping @Sendable () async -> Bool,
        claimTextFloor: @escaping @Sendable (UUID, Bool) async -> Bool,
        replaceTextFloor: @escaping @Sendable (UUID, UUID?) async -> Bool,
        softStop: @escaping @Sendable (UUID, Bool) async -> Bool,
        feed: @escaping @Sendable (String, UUID) async -> Bool,
        flush: @escaping @Sendable (UUID) async -> Bool,
        record: @escaping @Sendable (ReadDelivery) -> Void,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.roomIsQuiet = roomIsQuiet
        self.voiceOwnsFloor = voiceOwnsFloor
        self.claimTextFloor = claimTextFloor
        self.replaceTextFloor = replaceTextFloor
        self.softStop = softStop
        self.feed = feed
        self.flush = flush
        self.record = record
        self.sleep = sleep
    }

    package static let live = FollowUpFloorHooks(
        roomIsQuiet: {
            if await MaryRuntime.speaker.isSpeaking { return false }
            return await !TextTurnRunner.shared.isRunning()
        },
        voiceOwnsFloor: { await MaryRuntime.voiceSession.current() != nil },
        claimTextFloor: { lease, hardStop in
            await MaryRuntime.speaker.claimTextFloor(lease, hardStop: hardStop)
        },
        replaceTextFloor: { lease, expected in
            await MaryRuntime.speaker.replaceTextFloor(lease, replacing: expected)
        },
        softStop: { lease, handoff in
            await MaryRuntime.speaker.softStop(lease: lease, handoff: handoff)
        },
        feed: { text, lease in await MaryRuntime.speaker.feed(text, lease: lease) },
        flush: { lease in await MaryRuntime.speaker.flush(lease: lease) },
        record: { ReadDeliveryLedger.shared.record($0) },
        sleep: { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    )
}

package actor FollowUpSpeech {

    package static let shared = FollowUpSpeech()

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "chat.followup")

    /// How often the hold re-asks whether the room went quiet. The voice
    /// pipeline polls at the same 200 ms for the same reason: a follow-up
    /// should land in the pause, not half a second after it.
    static let pollInterval: TimeInterval = 0.2

    private let hooks: FollowUpFloorHooks
    private let budget: TimeInterval
    /// The exchange currently on screen — `.turnBegan`'s id, stamped by
    /// `TextTurnRunner`. Text mode's `currentUserTurnID`.
    private var currentTurnID: UUID?
    /// User turn claimed before brain emits exchange id — no detached take during the gap.
    private var awaitingUserTurnID = false
    /// Logical user-turn lease on every detached delivery. New claim makes old Tasks inert.
    private var userTurnLease = UUID()
    /// The physical speaker lease currently associated with the logical text
    /// turn. It changes when a follow-up takes the floor, but only through the
    /// compare-and-swap handoff above.
    private var speakerFloorLease: UUID?
    /// Serialization chain — each delivery awaits earlier ones. Same as enqueueFollowUp.
    private var chain: Task<Void, Never>?

    package init(
        hooks: FollowUpFloorHooks = .live,
        budget: TimeInterval = FollowUpFloor.quietBudget
    ) {
        self.hooks = hooks
        self.budget = budget
    }

    /// Kind of late utterance. Equatable is explicit — `.ambient` carries a value.
    package enum Delivery: Sendable, Equatable {
        /// A finished result. Today's behaviour, unchanged.
        case answer
        /// "Still working on …" — spoken only into an already-quiet room,
        /// never cutting in, never held, and never booked in the ledger.
        case progress
        /// Unprompted remark. May hold for a pause; never cuts in. Trace, not read ledger.
        case ambient(UUID)
    }

    /// Text-mode barge-in — earlier than .turnBegan. Stops audio, revokes detached leases.
    @discardableResult
    package func beginUserTurn() async -> UUID? {
        let lease = UUID()
        userTurnLease = lease
        // Do not advertise a writer until the speaker accepts the claim.
        speakerFloorLease = nil
        currentTurnID = nil
        awaitingUserTurnID = true
        // Cancelling the tail wakes ordinary waiting work quickly. Earlier
        // links can still resume, so the logical lease and speaker-owned
        // floor lease are the actual correctness boundaries.
        chain?.cancel()
        let claimed = await hooks.claimTextFloor(lease, true)
        // A second input can begin while the speaker claim is suspended. Its
        // lease is authoritative even if this older claim happened to reach
        // the speaker first; never publish the old id back into this actor.
        guard userTurnLease == lease, claimed else { return nil }
        speakerFloorLease = lease
        return lease
    }

    /// Compatibility entry point for the test seam and any caller that is
    /// already on the current floor lease.
    package func noteUserTurn(_ id: UUID) {
        noteUserTurn(id, lease: userTurnLease)
    }

    /// Attach the brain-issued exchange id to the user turn that claimed the
    /// floor.  A late `.turnBegan` from a cancelled run must not re-open the
    /// floor for that run's follow-ups.
    package func noteUserTurn(_ id: UUID, lease: UUID) {
        guard lease == userTurnLease else { return }
        currentTurnID = id
        awaitingUserTurnID = false
    }

    /// Enqueue a finished follow-up. Returns once the link is in the chain.
    package func enqueue(_ text: String, origin: UUID?, as delivery: Delivery = .answer) {
        guard !text.isEmpty else { return }
        let previous = chain
        let lease = userTurnLease
        chain = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.deliver(text, origin: origin, as: delivery, lease: lease)
        }
    }

    /// Test seam — the chain is the ordering guarantee, so a test that asserts
    /// on delivery has to be able to wait for it.
    package func drain() async {
        await chain?.value
    }

    private func owns(_ lease: UUID) -> Bool {
        !Task.isCancelled && lease == userTurnLease
    }

    /// Feed and drain under the delivery's lease. Guard between feed and flush.
    @discardableResult
    private func speak(
        _ text: String,
        userTurnLease: UUID,
        speakerLease: UUID
    ) async -> Bool {
        guard owns(userTurnLease) else { return false }
        guard await hooks.feed(text, speakerLease), owns(userTurnLease) else { return false }
        guard await hooks.flush(speakerLease) else { return false }
        return owns(userTurnLease)
    }

    private func deliver(
        _ text: String,
        origin: UUID?,
        as delivery: Delivery,
        lease: UUID
    ) async {
        guard owns(lease) else { return }
        // A live voice session owns the speaker; the pipeline plays its own
        // follow-ups through its own origin gate.
        if await hooks.voiceOwnsFloor() { return }
        guard owns(lease) else { return }

        // Progress: no softStop, no hold, no ReadDelivery row.
        if delivery == .progress {
            // Progress is deliberately never held.  It also may not bridge a
            // user-turn boundary while the new exchange id is still pending.
            guard !awaitingUserTurnID,
                  await hooks.roomIsQuiet(),
                  !(await hooks.voiceOwnsFloor()),
                  owns(lease)
            else { return }
            // Progress has no claim to preempt; the room is already quiet.
            // It still takes a fresh physical lease so an old primary router
            // cannot feed after this line starts.
            let speakerLease = UUID()
            let expectedSpeakerLease = speakerFloorLease
            guard await hooks.replaceTextFloor(speakerLease, expectedSpeakerLease),
                  owns(lease),
                  self.speakerFloorLease == expectedSpeakerLease,
                  !(await hooks.voiceOwnsFloor())
            else { return }
            self.speakerFloorLease = speakerLease
            // Quiet handoff: softStop clears unsynthesized draft, cuts no audible speech.
            guard await hooks.softStop(speakerLease, true), owns(lease),
                  !(await hooks.voiceOwnsFloor())
            else { return }
            _ = await speak(text, userTurnLease: lease, speakerLease: speakerLease)
            return
        }

        // Ambient waits, never cuts — nil origin is never stale, so the answer ladder would cut in.
        if case .ambient(let candidateID) = delivery {
            var waited: TimeInterval = 0
            var recordedHold = false
            while true {
                guard owns(lease) else {
                    return
                }
                // Voice session owns the speaker — pipeline books its own ambient row.
                if await hooks.voiceOwnsFloor() { return }
                // Split, not `&&`: the right side of `&&` is an autoclosure
                // and cannot hold an `await`.
                let quiet = await hooks.roomIsQuiet()
                let clear = !awaitingUserTurnID && quiet
                switch AmbientVoiceFloor.verdict(floorIsClear: clear, waited: waited) {
                case .speakNow:
                    break
                case .drop:
                    return
                case .waitForQuiet:
                    if !recordedHold {
                        recordedHold = true
                    }
                    await hooks.sleep(AmbientVoiceFloor.pollInterval)
                    waited += AmbientVoiceFloor.pollInterval
                    continue
                }
                break
            }
            // The room is quiet, so this claim cuts no audible speech — it
            // only clears a previous writer's unsynthesized draft, exactly as
            // the progress arm above does.
            let speakerLease = UUID()
            let expectedSpeakerLease = speakerFloorLease
            guard await hooks.replaceTextFloor(speakerLease, expectedSpeakerLease),
                  owns(lease),
                  self.speakerFloorLease == expectedSpeakerLease,
                  !(await hooks.voiceOwnsFloor())
            else {
                return
            }
            self.speakerFloorLease = speakerLease
            guard await hooks.softStop(speakerLease, true), owns(lease),
                  !(await hooks.voiceOwnsFloor())
            else {
                return
            }
            let spoke = await speak(text, userTurnLease: lease, speakerLease: speakerLease)
            return
        }

        var waited: TimeInterval = 0
        var recordedHold = false
        while true {
            guard owns(lease) else { return }
            // beginUserTurn precedes .turnBegan — wait for id, do not treat nil as not-stale.
            if awaitingUserTurnID {
                guard waited < budget else { return }
                await hooks.sleep(Self.pollInterval)
                waited += Self.pollInterval
                continue
            }
            // Re-read the current turn EVERY pass: the wait may span a whole
            // new user turn, and a follow-up that was fresh when it finished
            // is stale the moment the user asks something else.
            let verdict = FollowUpFloor.verdict(
                origin: origin,
                currentTurn: currentTurnID,
                roomIsQuiet: await hooks.roomIsQuiet(),
                waited: waited,
                budget: budget)
            switch verdict {
            case .speakNow:
                // Cut only for the exchange still on screen.
                guard !(await hooks.voiceOwnsFloor()), owns(lease) else { return }
                // Detached result becomes the physical writer before yielding the old line.
                let speakerLease = UUID()
                let expectedSpeakerLease = speakerFloorLease
                guard await hooks.replaceTextFloor(speakerLease, expectedSpeakerLease),
                      owns(lease),
                      self.speakerFloorLease == expectedSpeakerLease,
                      !(await hooks.voiceOwnsFloor())
                else { return }
                self.speakerFloorLease = speakerLease
                // Always clear the replaced writer's draft. Stale path is quiet — not a cut-in.
                guard await hooks.softStop(speakerLease, true), owns(lease),
                      !(await hooks.voiceOwnsFloor())
                else { return }
                guard await speak(text, userTurnLease: lease, speakerLease: speakerLease) else { return }
                hooks.record(ReadDelivery(
                    route: .spokenDetached, detail: "follow-up", characters: text.count))
                return
            case .waitForQuiet:
                if !recordedHold {
                    recordedHold = true
                    hooks.record(ReadDelivery(
                        route: .heldForQuiet, detail: "origin off screen",
                        characters: text.count))
                }
                await hooks.sleep(Self.pollInterval)
                waited += Self.pollInterval
            case .drop:
                // The transcript already carries it under its own exchange —
                // only the ear misses it, and the ledger says so out loud
                // instead of leaving another silence to trace.
                Self.log.info("follow-up dropped — origin off screen and the room never went quiet")
                hooks.record(ReadDelivery(
                    route: .droppedStale, detail: "origin off screen, room never went quiet",
                    characters: text.count))
                return
            }
        }
    }
}
