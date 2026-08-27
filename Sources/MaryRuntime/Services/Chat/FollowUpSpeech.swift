//
//  FollowUpSpeech.swift
//  Mary
//
//  TEXT MODE'S FOLLOW-UP FLOOR — the twin of `VoicePipeline`'s origin gate,
//  and the hole it was written to close.
//
//  THE FAILURE THIS PREVENTS (confirmed against a live user session, and
//  flagged as "observed but not fixed" during the earlier late-append round):
//  `ProactiveBridge`'s `.followUpCompleted` arm had `origin` in hand for the
//  transcript mirror and the speaking Task never consulted it. It read, in
//  full:
//
//      Task {
//          guard await MaryRuntime.voiceSession.current() == nil else { return }
//          await MaryRuntime.speaker.softStop()
//          await MaryRuntime.speaker.feed(fullText)
//          await MaryRuntime.speaker.flush()
//      }
//
//  Three defects in five lines. It `softStop`s whatever is speaking — so a
//  follow-up narrating turn N cuts into turn N+1's answer, which is the
//  reported symptom verbatim: a calendar answer that "arrived glued onto a
//  later reply". It is a bare detached `Task`, so two follow-ups finishing
//  together interleave into the speaker's SINGLE text buffer — the exact
//  failure `MaryBrain.enqueueFollowUp`'s own comment warns about. And it
//  never waits: a follow-up that cannot speak now is spoken anyway, wherever
//  "now" happens to be.
//
//  THE USER'S RULE, adopted verbatim: "A late follow-up never cuts in: if its
//  originating exchange is no longer on screen it waits for genuine quiet,
//  and if the moment has passed it is DROPPED rather than spoken into the
//  wrong context. The transcript still shows it under its own exchange."
//
//  The decision itself is `FollowUpFloor.verdict` — a pure function over
//  (origin, current turn, quiet, waited), so the rule is testable without a
//  speaker, a brain or a clock. `FollowUpSpeech` is the thin actor that
//  applies it and serializes delivery.
//

import MaryAmbient
import MaryBrain
import MaryVoice
import Foundation
import os

/// The pure rule. Mirrors `VoicePipeline.isStaleFollowUpOrigin` +
/// `playFollowUpWhenQuiet`, deliberately: two modes disagreeing about when a
/// follow-up may take the floor is how one of them ends up wrong.
package enum FollowUpFloor {

    package enum Verdict: Equatable {
        /// The floor is this follow-up's to take (cutting in if need be).
        case speakNow
        /// Stale and the room is busy — hold, and ask again shortly.
        case waitForQuiet
        /// Stale, still busy, and out of budget. The moment has passed.
        case drop
    }

    /// How long a stale follow-up may wait for quiet before the moment is
    /// gone. Matches `VoicePipeline.playFollowUpWhenQuiet`'s 15 s on purpose —
    /// it covers an utterance plus its reply, and past that the answer would
    /// be an interruption rather than a reply.
    static let quietBudget: TimeInterval = 15

    /// Is this follow-up narrating an exchange the user has already moved
    /// past? A STANDALONE notice (nil origin — the coding bridge's "that
    /// change didn't go through") belongs to no exchange and can never be
    /// stale; it keeps its urgency. Before any turn has begun there is
    /// nothing to be stale against.
    package static func isStale(origin: UUID?, currentTurn: UUID?) -> Bool {
        guard let origin, let currentTurn else { return false }
        return origin != currentTurn
    }

    /// May this follow-up `softStop` what is currently speaking? ONLY when it
    /// belongs to the exchange still on screen. This single `false` is the
    /// glued-on-a-later-reply bug.
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
        // Quiet is quiet: even stale narration is welcome when nothing is
        // playing. This is the wait's own exit, and the reason a late answer
        // still reaches the ear in the ordinary case.
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
    /// Claim the speaker's *own* generation. The UUID is supplied by this
    /// actor so TextTurnRunner, the detached follow-up, and the speaker agree
    /// on one concrete writer identity. `hardStop` is true only for a new
    /// user turn; a follow-up first claims its new lease, then soft-stops the
    /// previous writer at a sentence boundary.
    package var claimTextFloor: @Sendable (UUID, Bool) async -> Bool
    /// A detached follow-up may only replace the physical writer it observed
    /// (or an idle speaker after that writer finished). This closes the last
    /// cross-actor race: an old delivery that reaches the speaker after a new
    /// user turn must be refused there, not merely noticed afterwards.
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
    /// A user turn is claimed before the brain has emitted its exchange id.
    /// During that short gap no detached line is allowed to take the speaker:
    /// an old follow-up cannot exploit the `currentTurnID == nil` loophole,
    /// and a new one will be evaluated once the turn has its real id.
    private var awaitingUserTurnID = false
    /// Every queued or active detached delivery carries this *logical* user
    /// turn lease. Claiming a new user turn replaces it, which makes old Tasks
    /// inert even if they were already queued behind the serialization chain
    /// or resume after an await. Speaker mutations carry their own physical
    /// floor lease below; the two identities deliberately differ when a
    /// follow-up preempts the still-streaming primary reply.
    private var userTurnLease = UUID()
    /// The physical speaker lease currently associated with the logical text
    /// turn. It changes when a follow-up takes the floor, but only through the
    /// compare-and-swap handoff above.
    private var speakerFloorLease: UUID?
    /// THE SERIALIZATION CHAIN. Each delivery awaits every earlier one, so
    /// two follow-ups finishing together speak one after another instead of
    /// interleaving into the speaker's single text buffer and garbling both.
    /// Same invariant as `MaryBrain.enqueueFollowUp`, applied on the app
    /// side of the channel where the text-mode speech actually happens.
    private var chain: Task<Void, Never>?

    package init(
        hooks: FollowUpFloorHooks = .live,
        budget: TimeInterval = FollowUpFloor.quietBudget
    ) {
        self.hooks = hooks
        self.budget = budget
    }

    /// WHAT KIND OF LATE UTTERANCE THIS IS. The floor's rules were written for
    /// an ANSWER — something worth cutting in for, worth waiting fifteen
    /// seconds for, and worth a delivery row. A routine's progress line is
    /// none of those, and saying so here keeps one seam rather than growing a
    /// second speaking path in `ProactiveBridge`.
    /// EQUATABLE IS EXPLICIT because `.ambient` carries a value: an enum with
    /// no associated values gets `==` for free, and the arm below compares
    /// against `.progress`. Adding the payload silently removes that synthesis.
    package enum Delivery: Sendable, Equatable {
        /// A finished result. Today's behaviour, unchanged.
        case answer
        /// "Still working on …" — spoken only into an already-quiet room,
        /// never cutting in, never held, and never booked in the ledger.
        case progress
        /// AN UNPROMPTED REMARK, carrying the trace row it must report back
        /// to. It differs from `.progress` in exactly two ways: it may HOLD
        /// briefly for a pause (landing in the next one is right for a remark,
        /// where announcing a wait late is not), and it books its outcome in
        /// The proactive-speech trace rather than the read ledger — a remark is not a
        /// read, and its verdicts need history rather than a last value.
        ///
        /// Like `.progress` and unlike `.answer`, it NEVER cuts into a live
        /// answer. It outranks nothing.
        case ambient(UUID)
    }

    /// The text composer's input boundary.  It is deliberately earlier than
    /// `.turnBegan`: a completed response can still be audible, and a
    /// detached follow-up can still be waiting, when the user starts typing
    /// their next request.
    ///
    /// This is the single text-mode barge-in path.  It stops any ordinary
    /// response audio through the shared speaker and revokes every detached
    /// delivery's lease before a new brain request is even opened.
    @discardableResult
    package func beginUserTurn() async -> UUID? {
        let lease = UUID()
        userTurnLease = lease
        // Do not advertise a physical writer until the speaker has accepted
        // it. A voice session can start between text mode's UI guard and this
        // actor hop; pretending that a rejected claim owns the floor would
        // make the text router silently send a lease the speaker refuses.
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

    /// Hand a finished follow-up to the floor. Returns as soon as the link is
    /// in the chain — the proactive event loop must keep pumping while a
    /// follow-up waits for quiet, or a held one would stall every chip behind
    /// it.
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

    /// Feed and drain under the delivery's lease.  The guard between `feed`
    /// and `flush` is essential: a hard stop clears the shared speaker, but a
    /// detached Task that resumes afterwards must not flush whatever a newer
    /// response has since put there.
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

        // A PROGRESS LINE TAKES NOTHING AND WAITS FOR NOTHING. It never calls
        // `softStop` (cutting into a live answer to say there is no answer yet
        // is the preemption `ProactiveEvent.routineProgress` exists to avoid),
        // it never enters the hold loop (a wait announced fifteen seconds late
        // is worse than an unannounced one), and it books no `ReadDelivery` —
        // the ledger is a last-value box answering "where did the read I just
        // watched go?", and a notice that no read has happened yet would
        // overwrite that answer with a non-answer.
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
            // A quiet handoff has no audible sentence to preserve, but it can
            // still have a previous writer's unsynthesized buffer or a
            // synthesis task in flight. `softStop` clears that draft; when
            // the room is truly quiet it returns immediately and cuts no
            // audible speech.
            guard await hooks.softStop(speakerLease, true), owns(lease),
                  !(await hooks.voiceOwnsFloor())
            else { return }
            _ = await speak(text, userTurnLease: lease, speakerLease: speakerLease)
            return
        }

        // AN UNPROMPTED REMARK WAITS, BUT NEVER CUTS. The `.answer` ladder
        // below reaches `.speakNow` for any non-stale follow-up even into a
        // BUSY room — and a nil origin is never stale, so routing an ambient
        // line through it would `softStop` the reply currently speaking and
        // truncate it permanently. That is the whole reason this is its own
        // arm rather than another origin on the existing one.
        if case .ambient(let candidateID) = delivery {
            var waited: TimeInterval = 0
            var recordedHold = false
            while true {
                guard owns(lease) else {
                    return
                }
                // A live voice session owns the speaker and plays its own
                // ambient line through the pipeline's arm, which books its own
                // row. Returning silently here is what keeps one candidate
                // from collecting two contradictory deliveries.
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
            // `beginUserTurn` happens before the next brain `.turnBegan`.
            // Wait briefly for that identity rather than treating nil as
            // "nothing is stale" and letting a prior detached answer speak
            // in the input-to-turn-began gap.
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
                // The cut is allowed ONLY for the exchange still on screen.
                // For a stale follow-up we got here because the room went
                // quiet, so there is nothing to cut into anyway — the guard
                // is belt and braces on the rule that matters.
                guard !(await hooks.voiceOwnsFloor()), owns(lease) else { return }
                // A detached result becomes the new physical writer before it
                // yields the old line. This revokes the primary router at the
                // speaker itself; otherwise its next token can append during
                // this follow-up's flush.
                let speakerLease = UUID()
                let expectedSpeakerLease = speakerFloorLease
                guard await hooks.replaceTextFloor(speakerLease, expectedSpeakerLease),
                      owns(lease),
                      self.speakerFloorLease == expectedSpeakerLease,
                      !(await hooks.voiceOwnsFloor())
                else { return }
                self.speakerFloorLease = speakerLease
                // Always clear the replaced writer's *draft*. When this
                // follow-up is current, `softStop` also yields audible audio
                // at a sentence boundary; when it is stale, the verdict only
                // reached this branch because the room was quiet, so this is
                // a non-audible reset rather than a cut-in.
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
