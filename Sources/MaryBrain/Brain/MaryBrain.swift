//
//  MaryBrain.swift
//  MaryBrain
//
//  The one place conversation history and the Skill loop live. Voice mode
//  (VoicePipeline) and text mode (ChatService.SendText) both drive this actor,
//  which serializes any accidental overlap; the selected InferenceEngine is a
//  swappable transport underneath.
//
//  Two turn shapes:
//  - SEER MODE (a SeerChatProviding is wired and ready): the reply streams
//    from Seer with the spoken history; the engine runs concurrently as a
//    silent orchestrator that only executes skills. Seer owns every spoken
//    word; orchestrator prose is kept solely as an offline fallback.
//  - LOCAL MODE (no Seer): today's single-engine loop, unchanged.
//

import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

// SPLIT ACROSS Brain/ BY CONCERN — this file keeps the actor declaration,
// every stored property and constant, the designated init, the *ForTesting
// setters that touch stored state, and the LanguageResponder surface.
// Everything else moved out verbatim, one concern per file:
//   AbilityDispatching.swift        the dispatcher seam + SeerPass
//   BrainConcurrency.swift          ProactiveMulticast, LaneEmitter, TurnBox, AsyncGate
//   MaryBrain+Configuration.swift the public set* wiring surface
//   MaryBrain+History.swift       epoch-guarded history writes + trimming
//   MaryBrain+TurnLoop.swift      runTurn / runTurnBody
//   MaryBrain+Route.swift         the revision spine (the taxonomy seam)
//   MaryBrain+SeerTurn.swift      seerTurn + lane result types
//   MaryBrain+Lanes.swift         runSeerLane / runRealtimeSeerLane / runOrchestratorLane
//   MaryBrain+Routines.swift      detached-routine lifecycle + follow-up chain
//   MaryBrain+LocalTurn.swift     the single-engine loop + nudges
//   MaryBrain+Deposit.swift       archive(...)
//   MaryBrain+Vocabulary.swift    the deterministic sentence builders
//   MaryBrain+GroundedText.swift  the grounded-text composition statics
//   MaryBrain+UtteranceGates.swift  bare yes/no, correction, accepted-offer gates
//   MaryBrain+Types.swift         RevisionVeto, LocatedArtifact, ArtifactRevisionVeto, WorldVeto
// Members promoted private → internal for the split are annotated
// "internal for file split — treat as private".

public actor MaryBrain: LanguageResponder {

    // internal for file split — treat as private
    var engine: any InferenceEngine

    /// WHAT PRODUCED THIS EPISODE — stamped on every one, because a dataset
    /// mixing an on-device model's turns with a hosted model's is two datasets
    /// wearing one name, and nothing downstream could tell them apart later.
    func behavioralProvenance(lane: String = "dual") -> EpisodeProvenance {
        EpisodeProvenance(
            engine: engine.choice.rawValue,
            lane: lane,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }
    // internal for file split — treat as private
    var dispatcher: (any AbilityDispatching)?
    /// Resolves a reference through the runtime's plugin roster when available.
    // internal for file split — treat as private
    var referentResolver: (@Sendable (ReferenceAct) -> ReferenceDecision)?
    /// Applies a one-word correction and returns what it re-aimed to. Installed
    /// by the runtime, which owns the roster; nil in a headless probe, and nil
    /// means a correction is recognised and simply has nowhere to land.
    // internal for file split — treat as private
    var referenceCorrector:
        (@Sendable (ResolvedReferent) -> ReferenceResolver.Rival?)?

    // internal for file split — treat as private
    var systemPromptProvider: @Sendable () -> String
    /// Seer chat lane; nil (or not ready) = local single-engine turns.
    // internal for file split — treat as private
    var seerChat: (any SeerChatProviding)?
    /// Optional realtime WS route (opt-in via Settings); nil = classic only.
    // internal for file split — treat as private
    var seerRealtime: (any SeerRealtimeProviding)?
    /// Persona/instructions for Seer requests; separate from the engine's
    /// system prompt (which carries the whole Skill doctrine Seer must not see).
    /// Takes the turn's grounded-results block (nil for a normal turn) so the
    /// FOLLOW-UP persona is built by the same provider — it used to call
    /// MaryPrompts directly and therefore spoke with no capability line and
    /// no live context, the most retrieval-exposed turn in the system.
    ///
    /// The second parameter is the WORLD to resolve against, and it exists
    /// because routing the follow-up through this provider introduced a new
    /// lie: `runTurn` clears the utterance override in a `defer`, so by the
    /// time a detached routine settles the provider resolves AMBIENT focus. A
    /// routine spawned by "proofread this" while Xcode was frontmost then
    /// spoke a follow-up claiming "you're pair-coding in Xcode", handed over
    /// Xcode source as the live work, and scoped retrieval to the wrong
    /// group. Callers that know which world spawned them pass it; nil means
    /// "resolve live", which is what an in-turn pass wants.
    // internal for file split — treat as private
    var seerInstructionsProvider: @Sendable (SeerPass) -> String = { pass in
        MaryPrompts.seerInstructions(
            groundedResults: pass.groundedResults,
            readPassages: pass.readPassages,
            readReport: pass.readReport,
            conversational: pass.conversational,
            // The running-actions note is a SECTION now rather than a string
            // the turn loop appends afterwards, so every provider — including
            // this default, which is what the tests run against — has to pass
            // it through or the note silently stops reaching the voice.
            runningActions: pass.runningActionLabels)
    }
    /// Fire-and-forget archive of Skill results into the user's totem.
    // internal for file split — treat as private
    var depositor: (any ContextDepositing)?
    /// WHICH document/project the archive should file this turn's results
    /// under. Read SYNCHRONOUSLY at archive time (the deposit itself is
    /// detached and lands later, when focus may have moved). Defaults to
    /// unfocused, which reproduces today's owner-wide pool exactly — the app
    /// installs the real resolver alongside the prompt providers, from the
    /// same focus decision, so the archive and the prompt can never name
    /// different documents.
    // internal for file split — treat as private
    var depositSubjectProvider: @Sendable () -> DepositSubject = { .unfocused }
    /// THE CROSS-CUTTING STORES, injected as one bundle (`BrainWiring`).
    /// Default-fresh: an uninjected brain is isolated by construction; the
    /// composition root passes the process-wide instances explicitly.
    // internal for file split — treat as private
    var wiring: BrainWiring
    /// Where the last READ went — the debugger's row, and the only place in
    /// the process that answers "did that Skill result reach the voice?".
    /// Injectable so a pin never races the process-wide box. Seeded from
    /// `wiring`; the setter seam below stays for existing tests.
    // internal for file split — treat as private
    var readLedger: ReadDeliveryLedger
    /// THE SHORT-TERM MEMORY AWARENESS. The turn loop is one of its four
    /// writers: it publishes the UTTERANCE the budget policy ranks against
    /// (before either prompt is built) and writes back WHAT WAS SPOKEN about a
    /// fact once the reply has settled. The watchers and the dispatcher write
    /// the facts themselves. Injectable, like the ledger, so a pin never races
    /// the process-wide box. Seeded from `wiring`.
    // internal for file split — treat as private
    var ambient: AmbientContextStore
    /// Refreshes volatile frontmost context, such as an AX text selection,
    /// immediately before the turn is classified and prompted.
    // internal for file split — treat as private
    var turnContextPreparer: (@Sendable () async -> Void)?
    /// Lane join/detach visibility — the regression class this measures is
    /// fast actions detaching because of QUEUEING, not work.
    // internal for file split — treat as private
    static let laneLog = Logger(subsystem: "nyc.rao.mary", category: "lanes")

    // internal for file split — treat as private
    var history: [BrainTurn] = []
    /// The last application the user named (or that exact ApplicationProfile
    /// owned while they spoke). Mary's request surface may become frontmost
    /// before a typed follow-up, so live NSWorkspace focus alone cannot resolve
    /// “Where is it?” or “make another one.” This is conversational salience,
    /// not durable focus and never an authorization grant.
    // internal for file split — treat as private
    var recentApplicationReferent: (id: String, resolvedAt: Date)?
    // internal for file split — treat as private
    static let applicationReferentLifetime: TimeInterval = 5 * 60
    /// THE PASSAGE THE CONVERSATION IS ABOUT — armed when a turn grounds on a
    /// selection brief, spent by a bare acceptance one exchange later.
    ///
    /// THE FAILURE THIS FIXES (live, in Pages): "What do you think about this
    /// part I wrote" grounded a correct critique on the turn-scoped selection
    /// channel; Mary offered to tighten it; "Yes please" arrived as a turn
    /// that is neither deictic nor a revision verb, so the route re-gated the
    /// selection out of the prompt AT THE MOMENT THE USER ACCEPTED, and the
    /// lane reworded a garbled chat utterance instead. The selection's
    /// one-turn claim is right (a stale highlight must not leak into
    /// unrelated turns) — but the TEXT DISCUSSED is conversational salience,
    /// `recentApplicationReferent`'s sibling, and it may outlive the turn.
    struct DiscussedPassageReferent: Sendable, Equatable {
        /// The exact handoff text — never the prompt-clipped fact.
        var text: String
        var world: AmbientWorld
        var applicationID: String?
        /// The document's title, for the honest-miss sentence.
        var subject: String?
        var armedAt: Date
        /// The arming turn's user-turn id — the adjacency evidence. An
        /// intervening exchange kills the acceptance.
        var armedByExchange: UUID
    }
    // internal for file split — treat as private
    var discussedPassageReferent: DiscussedPassageReferent?

    /// THE PROSE Mary OFFERED IN HER LAST SPOKEN REPLY, so that accepting it
    /// writes those exact bytes. See `OfferedProse` for why this exists.
    ///
    /// A SIBLING OF `discussedPassageReferent`, NOT A WIDENING OF IT, and the
    /// separation is load-bearing. That one holds the USER's selection and is
    /// spent by `bareAcceptance` on a bare "yes please" to run the REVISION
    /// spine. If a spoken offer overwrote it, a "yes please" answering "want
    /// me to tighten this selection?" would stop replacing the selection and
    /// start typing at the caret — a different act on a different target, from
    /// the same word. Two referents, two acceptance roads, and the roads
    /// cannot cross: `bareDecision`'s closed affirmative set contains no write
    /// verb, and this one requires one.
    struct OfferedProseReferent: Sendable, Equatable {
        /// Mary's exact bytes, emphasis and the outer quote pair removed,
        /// everything inside preserved.
        var text: String
        /// The place the offer was made about — a place, so an offer made in a
        /// TAUGHT application can name it. Nil when no world led the turn.
        var place: AmbientPlace?
        var armedAt: Date
        /// The user turn that PROMPTED the offer — the adjacency evidence, the
        /// same shape `DiscussedPassageReferent.armedByExchange` carries.
        var armedByExchange: UUID
    }
    // internal for file split — treat as private
    var offeredProseReferent: OfferedProseReferent?
    /// The PREVIOUS turn's user-turn id, captured at each turn's entry before
    /// the current one overwrites it — what `bareAcceptance`'s adjacency gate
    /// compares against. Trim-proof: no history scan.
    // internal for file split — treat as private
    var lastUserTurnID: UUID?
    /// The in-flight turn's exchange anchor: set the moment the user turn
    /// lands in history, cleared at every turn exit. A NEW turn that finds
    /// this non-nil arrived while another turn was mid-flight — requirement:
    /// it supersedes CLEANLY, removing the partial exchange from history AND
    /// telling the UI to drop the same bubbles (the two views must never
    /// disagree). Keyed by BrainTurn.id, not position, so removal is exact
    /// and idempotent under any unwind interleaving.
    // internal for file split — treat as private
    var openExchange: (userTurnID: UUID, epoch: UInt64)?
    /// Ready LoRAs by discipline, supplied by Runtime. Nil lookup = no Life.
    // internal for file split — treat as private
    var lifeLoRALookup: (@Sendable (AbilityID) -> LifeLoRASlot?)?
    // internal for file split — treat as private
    let turnBox = TurnBox()
    /// Brain-initiated events outside turns — routine progress + follow-ups.
    // internal for file split — treat as private
    let proactive = ProactiveMulticast()

    // internal for file split — treat as private
    var activeRoutines: [UUID: ActiveRoutine] = [:]
    /// ROUTINES THE WATCHDOG GAVE UP ON, kept just long enough for a LATE
    /// result to still be delivered.
    ///
    /// THE FAILURE THIS FIXES: `finishRoutine`'s first line was `guard let
    /// routine = activeRoutines[id] else { return }`, and `expireRoutine`
    /// removes the entry — so a lane that came back one second after the
    /// watchdog fired had its whole result dropped on the floor, silently,
    /// having already told the user "that one stalled… ask me again and I'll
    /// retry". Completed work was denied and the user was invited to pay for
    /// it twice. A late answer is still an answer.
    ///
    /// BOUNDED, because a lane that never returns never consumes its entry.
    /// Two full watchdogs after cancellation is far past any honest hope of a
    /// result, and it is the same arithmetic the watchdog itself is made of.
    // internal for file split — treat as private
    var expiredRoutines: [UUID: LateRoutine] = [:]
    /// THE SETTLE HOP, TRACKED. The detach path spawns one unstructured task
    /// per routine to await the lane and run `finishRoutine`; untracked, it
    /// was the one piece of routine work nothing could enumerate — a test (or
    /// a teardown) that had awaited every lane could still race the settle
    /// writing into a stub. Registered at detach, self-removing when the
    /// settle returns. Write-only bookkeeping; `finishRoutine` is untouched.
    // internal for file split — treat as private
    var settleTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recently cleared routine, kept ONLY so tests can observe that
    /// the terminal path cancelled both of its clocks — `clearActiveRoutine`
    /// stashes it. Production never reads this.
    // internal for file split — treat as private
    var lastClearedRoutine: ActiveRoutine?
    /// How long past Seer's reply the lane may take and still join the turn
    /// (fast skills feel synchronous; slow ones detach and follow up).
    ///
    /// STATIC, because the speaker holds the same window. `KokoroStreamSpeaker
    /// .takeoverHoldNanoseconds` keeps synthesis from committing a word while
    /// the outcome could still arrive in-turn, and "the same window" is only
    /// true if both numbers can be read in one place — `TakeoverTests` pins
    /// them equal so they cannot drift apart in silence.
    static let laneJoinGraceNanoseconds: UInt64 = 250_000_000
    /// The LIVE spoken-turn grace — the watchdog's static-default /
    /// instance-live split applied here. The STATIC above stays the single
    /// source of truth (`TakeoverTests` pins it against the speaker's
    /// takeover hold, and that pin must keep reading one authoritative
    /// number); production never mutates this, and a test that shrinks or
    /// stretches it is exercising the same ordering the shipped value does.
    // internal for file split — treat as private
    var laneJoinGraceLiveNanoseconds: UInt64 = MaryBrain.laneJoinGraceNanoseconds
    /// The ACTION-turn grace: no voice is racing the lane, so waiting longer
    /// keeps chips + failure lines in-turn instead of detaching every
    /// command into a routine 250ms after an instantly-empty Lane A.
    // internal for file split — treat as private
    var actionJoinGraceNanoseconds: UInt64 = 5_000_000_000
    /// How long fetch-first may hold the voice. The read itself is ~100–300ms
    /// of AppleScript; this exists for the pathological case, because
    /// ScriptRunner's own ceiling is 30 seconds and a wedged Pages must never
    /// buy silence. Past the budget the turn proceeds exactly as it does today
    /// — the read is a bonus, never a dependency.
    // internal for file split — treat as private
    static let preReadBudgetNanoseconds: UInt64 = 2_500_000_000
    /// The pre-lane LOOK's own ceiling — vision-sized, where the pre-read's
    /// 2.5s is AppleScript-sized. A look costs 0.1-0.8s of capture plus a
    /// 1-5s vision round trip (the 401 re-auth retry can double the HTTP
    /// leg). PRECISION FIRST (user decision 2026-08-11): 8s keeps almost
    /// every look answering in-turn; the FAST capture profile (smaller
    /// payload, see ScreenRegionCapture.CaptureProfile.fast) is what pulls
    /// TYPICAL latency to ≤3s. Past the ceiling the turn proceeds lookless
    /// and the description arrives as the spoken follow-up — the look is a
    /// bonus, never a dependency. This is the tunable.
    static let preLookBudgetNanoseconds: UInt64 = 8_000_000_000
    // internal for file split — treat as private
    static let turnContextRefreshBudgetNanoseconds: UInt64 = 1_000_000_000

    func setReadLedgerForTesting(_ ledger: ReadDeliveryLedger) {
        readLedger = ledger
    }

    func setAmbientStoreForTesting(_ store: AmbientContextStore) {
        ambient = store
    }

    func setActionJoinGraceForTesting(_ nanoseconds: UInt64) {
        actionJoinGraceNanoseconds = nanoseconds
    }

    func setLaneJoinGraceForTesting(_ nanoseconds: UInt64) {
        laneJoinGraceLiveNanoseconds = nanoseconds
    }

    /// Run `work`, or give up on it after `budget`. Cancellation-responsive
    /// (the group's racers both end), and the abandoned work is always a READ
    /// — nothing is left half-mutated by walking away from it.
    // internal for file split — treat as private
    func withNanosecondBudget<T: Sendable>(
        _ budget: UInt64, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Test seams: the Seer-wire view and the raw role sequence of history —
    /// the alternation invariant's observation points.
    func spokenMessagesForTesting() -> [SeerChatMessage] { spokenMessages() }
    func historyRolesForTesting() -> [BrainTurn.Role] { history.map(\.role) }
    /// Detached-routine wall-clock cap — a hung lane (an engine stuck at its
    /// network timeout, a Skill that never returns) must never leave the
    /// "still working" chip lit forever. Expiry now speaks an honest line
    /// (`expireRoutine`); it used to settle in silence, which is how a user
    /// could wait out the whole cap and be told nothing at all.
    ///
    /// SEVEN MINUTES, and the number is arithmetic rather than taste. It is the
    /// longest LEGITIMATE dependency underneath a lane — `Subprocess.run`'s 300 s
    /// ceiling on `swift build` / `swift test` — plus one bounded engine round
    /// (`StreamingHTTP.resourceTimeout`, 120 s), and nothing else down there is
    /// unbounded any more. Ten minutes was chosen when the layers below had no
    /// caps at all; it is far past the point the answer is still wanted, and it
    /// was also the window in which the old silent expiry destroyed one.
    /// Cutting deeper would kill real builds, which is the one thing a
    /// watchdog must never do.
    static let routineWatchdogDefault: UInt64 = 420_000_000_000   // 7 min
    // internal for file split — treat as private
    var routineWatchdogNanoseconds = MaryBrain.routineWatchdogDefault

    /// THE LANE'S VOICE — when a routine that is merely slow says so.
    ///
    /// THE FAILURE THESE FIX (confirmed against a live user session): "pulling
    /// up the Purpose section now…", then FIVE FULL MINUTES of silence, then a
    /// script error. Nothing anywhere between the utterance and the failure was
    /// counting. The watchdog above is a wall clock on the ROUTINE; these are
    /// the first wall clock on the WAIT, which is the thing the user is
    /// actually living through. The user's decision is fixed and it is not a
    /// cap: "Speak progress at ~45 s, keep working."
    ///
    /// FIRST MARK — 45 s, and it is a sum of the two things a healthy lane can
    /// legitimately be stuck inside:
    ///   `ScriptRunner.appleScriptTimeout` (30 s — the longest single Apple
    ///   Event a lane may wait on, and the ceiling a wedged Pages actually
    ///   sits at) + ~15 s of engine rounds around it.
    /// And it is STRICTLY BELOW `StreamingHTTP.resourceTimeout` (120 s), which
    /// is the point of choosing it rather than 60 or 90: a wedged engine round
    /// is announced a minute and a quarter before it dies, so the user hears
    /// "still working" while it is still true instead of hearing nothing until
    /// the failure.
    ///
    /// SECOND MARK — 210 s = `routineWatchdogDefault` / 2. Half the cap is the
    /// only division of it that needs no defence, and it lands INSIDE a real
    /// build: `Subprocess.run(timeout: 300)` on `swift build`
    /// (`BuildVerifier`) and `swift test` (`XcodePlugin`) is the binding
    /// legitimate dependency down there, so at 210 s a compiling lane is
    /// genuinely mid-build. The second line therefore reports honestly rather
    /// than promising a completion that is still 90 s away.
    ///
    /// TWO MARKS, NEVER REPEATING. A 45 s PERIOD would produce nine utterances
    /// before the watchdog fired, which is not a progress report, it is
    /// nagging. Two marks plus the terminal line is a ceiling of THREE spoken
    /// artefacts on a maximally-stalled turn.
    static let routineProgressFirstMark: UInt64 = 45_000_000_000    // 30 + ~15
    static let routineProgressSecondMark: UInt64 = 210_000_000_000  // 420 / 2
    static let routineProgressMarksDefault: [UInt64] = [
        routineProgressFirstMark, routineProgressSecondMark,
    ]
    /// Live values, instance-scoped for the same reason the watchdog is: a
    /// suite that had to wait forty-five real seconds to prove a line is
    /// spoken is a suite nobody runs, and an unrun pin is an absent one.
    // internal for file split — treat as private
    var routineProgressMarks = MaryBrain.routineProgressMarksDefault

    func setRoutineProgressMarksForTesting(_ marks: [UInt64]) {
        routineProgressMarks = marks
    }
    // internal for file split — treat as private
    var followUpChain: ChainEntry?

    /// THE FOLLOW-UP TIME LADDER. Each rung is strictly larger than the one it
    /// contains, so the INNERMOST bound is the one that normally fires and the
    /// outer ones only ever catch something the inner one could not. Every
    /// value is a WALL CLOCK on a path that had none.
    ///
    /// THE FAILURE THESE PREVENT (confirmed against a live user session): "what
    /// are my calendar events tomorrow" spoke its acknowledgement, rendered its
    /// `LIST_EVENTS` chip, and then produced nothing — ever. An earlier Pages
    /// routine's follow-up had wedged inside `seerChat.stream`, and
    /// `enqueueFollowUp` made that one hang permanent and global: no timeout,
    /// no cancellation, no reset, so entries N+1…∞ queued behind it across
    /// turns, topics and applications. The idle timeout everyone assumed
    /// bounded it does not: `request.timeoutInterval` is URLSession's IDLE
    /// timer, and an SSE stream emitting heartbeats but no `data:` chunks
    /// resets it forever.
    ///
    /// A CHAIN WHOSE PURPOSE IS ORDER MUST NOT BECOME A CHAIN THAT ENFORCES
    /// SILENCE. Ordering is worth waiting for; it is not worth an answer.

    /// The Seer round trip that COMPOSES one follow-up. Normally 1–5 s; past
    /// this the passage is recited by the deterministic fallback line instead,
    /// which is late and plain but true.
    static let followUpSpeechBudget: TimeInterval = 20
    /// One chain entry's whole body. Strictly above the speech budget so the
    /// inner bound is what normally fires — this rung exists to catch the
    /// awaits the inner one does not cover (`seerChat.isReady()`) and any body
    /// added later.
    static let followUpBodyBudget: TimeInterval = 25
    /// How long an entry waits for its PREDECESSOR. Strictly above the body
    /// budget, so a healthy (and now bounded) predecessor always finishes
    /// first and ordering holds; only a genuinely wedged one is stepped over.
    /// The wait is a constant, not a sum, so entry N+1 can never inherit entry
    /// N's delay — the chain drains rather than accumulating.
    static let followUpChainWaitBudget: TimeInterval = 30
    /// `finishRoutine`'s own wait, so settling still happens AFTER the speech
    /// in the healthy case (the chip covers the narration) while never being
    /// hostage to it. Strictly above wait + body, which is the longest a chain
    /// entry can now live.
    static let followUpHandoffBudget: TimeInterval = 60

    /// The live values, seeded from the ladder. Instance-scoped so a test can
    /// reach the wedged case in milliseconds — a suite that had to wait 30
    /// real seconds to prove the chain recovers is a suite nobody runs, and an
    /// unpinned recovery is the one that quietly regresses.
    // internal for file split — treat as private
    var speechBudget = MaryBrain.followUpSpeechBudget
    // internal for file split — treat as private
    var bodyBudget = MaryBrain.followUpBodyBudget
    // internal for file split — treat as private
    var chainWaitBudget = MaryBrain.followUpChainWaitBudget
    // internal for file split — treat as private
    var handoffBudget = MaryBrain.followUpHandoffBudget

    /// Test seam: the WHOLE ladder, scaled. Scaling rather than setting keeps
    /// the ratios — which are the contract — identical to production, so a test
    /// exercises the same ordering the shipped numbers do.
    /// Test seam: the chain itself, with no routine on top of it. The property
    /// that matters — a wedged entry must not take its successors with it — is
    /// a property of the CHAIN; driving it through two whole turns would pin
    /// the scheduler's turn interleaving instead of the thing under test.
    func enqueueFollowUpForTesting(_ body: @escaping @Sendable () async -> Void) async {
        await enqueueFollowUp(origin: nil) { _ in await body() }
    }

    func setFollowUpBudgetScaleForTesting(_ scale: Double) {
        speechBudget = Self.followUpSpeechBudget * scale
        bodyBudget = Self.followUpBodyBudget * scale
        chainWaitBudget = Self.followUpChainWaitBudget * scale
        handoffBudget = Self.followUpHandoffBudget * scale
    }
    /// Serializes ENGINE GENERATION across concurrent orchestrator lanes.
    /// Skill executions interleave freely; only the model rounds queue — the
    /// local MLX engine's concurrent-stream safety is not guaranteed, and
    /// serialized rounds cost little (lanes are mostly waiting on skills).
    // internal for file split — treat as private
    let engineGate = AsyncGate()

    func setRoutineWatchdogForTesting(_ nanoseconds: UInt64) {
        routineWatchdogNanoseconds = nanoseconds
    }

    /// Did the terminal path cancel BOTH of the last cleared routine's
    /// clocks? Structural proof for the "progress dies with the routine" pin
    /// — no waiting past marks required. Nil-tolerant: a routine born with no
    /// clock trivially cancelled it.
    func lastClearedRoutineClocksCancelledForTesting() -> Bool {
        guard let routine = lastClearedRoutine else { return false }
        return (routine.watchdogTask?.isCancelled ?? true)
            && (routine.progressTask?.isCancelled ?? true)
    }

    /// Awaits every STILL-ACTIVE routine's progress clock running down — the
    /// structural proof that no further mark can ever be spoken (the task
    /// returning is stronger than any amount of sleeping past the period).
    func awaitProgressClockRundownForTesting() async {
        for routine in activeRoutines.values {
            await routine.progressTask?.value
        }
    }

    /// Awaits every detached lane, settle hop, and follow-up chain entry, in
    /// waves (settling one routine can enqueue a chain entry); the wave cap
    /// surfaces a wedge as a `false` return instead of a hang. The call-site
    /// rule lives in BrainTestSupport.swift: a test whose dispatcher parks or
    /// delays ends with this (after releasing its holds) or with
    /// `cancelRoutinesForTesting()`.
    @discardableResult
    func awaitQuiescenceForTesting(maxWaves: Int = 16) async -> Bool {
        for _ in 0..<maxWaves {
            let lanes = activeRoutines.values.map(\.task)
            let settles = Array(settleTasks.values)
            // `followUpChain` is never nilled by design — a completed entry
            // is "drained", not "pending", so awaiting it is cheap and the
            // identity check below stops the loop from chasing it forever.
            let chainTask = followUpChain?.task
            for lane in lanes { _ = await lane.value }
            for settle in settles { await settle.value }
            if let chainTask { await chainTask.value }
            if activeRoutines.isEmpty, settleTasks.isEmpty,
               followUpChain?.task == chainTask {
                return true
            }
        }
        return false
    }

    /// Cancel everything, then drain — for tests that deliberately abandon a
    /// routine (timeout paths). Termination relies on ArrivalSignal's
    /// cancellation: a lane parked in a stub's `wait(until:)` resumes early
    /// when its task is cancelled.
    func cancelRoutinesForTesting() async {
        for (id, routine) in activeRoutines {
            routine.task.cancel()
            clearActiveRoutine(id: id)
        }
        for task in settleTasks.values { task.cancel() }
        await awaitQuiescenceForTesting()
    }

    /// Coding/writing focus signal — the per-turn utterance override rides
    /// it (an explicitly named domain wins for one turn). Test-injectable.
    /// Seeded from `wiring`.
    // internal for file split — treat as private
    var focusTracker: WorkspaceFocusTracker

    /// Rolling context window: the model keeps only the last N SPOKEN
    /// messages (user + Mary's replies; Skill chatter rides along with its
    /// exchange). Old context — including stale file reads — ages out
    /// continuously. Settable from Settings.
    // internal for file split — treat as private
    var historyMessageLimit = 12
    /// The subshell budget: enough rounds for real multi-step work
    /// (plan → command → observe → next), closed by a forced wrap-up.
    // internal for file split — treat as private
    let maxSkillRounds = 10

    public init(
        engine: any InferenceEngine,
        dispatcher: (any AbilityDispatching)? = nil,
        systemPrompt: String = MaryPrompts.system(plugins: [], projects: [:]),
        wiring: BrainWiring = BrainWiring()
    ) {
        self.engine = engine
        self.dispatcher = dispatcher
        self.systemPromptProvider = { systemPrompt }
        self.wiring = wiring
        self.readLedger = wiring.readLedger
        self.ambient = wiring.ambient
        self.focusTracker = wiring.focusTracker
    }

    // MARK: - Configuration

    /// Test seam: an isolated focus tracker so turn-override tests never
    /// touch the process-wide signal.
    func setFocusTrackerForTesting(_ tracker: WorkspaceFocusTracker) {
        self.focusTracker = tracker
    }
}
