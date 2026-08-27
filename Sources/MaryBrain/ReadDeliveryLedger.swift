//
//  ReadDeliveryLedger.swift
//  MaryBrain
//
//  Did the last thing Mary READ actually reach the lane that speaks?
//
//  THE FAILURE THIS MAKES VISIBLE (confirmed against a live bug): `pages_body`
//  returned "characters 12927–13835 of 15775, from \"batteries\"" and the
//  voice answered "I don't see anything about batteries". Every diagnostic in
//  the process reported healthy. The debugger's `delivery` row already
//  distinguished "voice + Skills" from "Skills only" — but it describes a
//  WATCHER's contribution, and a Skill result was permanently, invisibly
//  "Skills only" with no row anywhere saying so. Finding that took a full
//  trace; it should take a glance.
//
//  Deliberately a last-value box, not a log: the question this answers is
//  "where did the read I just watched happen go?", asked with the pane open
//  seconds later. The action log already keeps history.
//

import Foundation
import os

/// Where a read's text ended up.
public enum ReadRoute: String, Sendable, Equatable, CaseIterable {
    /// Fetch-first: read BEFORE the lanes spawned and carried into the voice's
    /// instructions with the live work. The intended path for a named part.
    case prefetched
    /// The lane detached and the routine follow-up spoke it — the path that
    /// always worked, and the reason a SLOWER read behaved better than a fast
    /// one before the inversion was closed.
    case spokenDetached
    /// It succeeded, joined inside the grace, and the AMBIENT CONTEXT STORE
    /// took it: registered as a `(world, namedRead:)` fact, so the passage
    /// rides the NEXT turn's prompt with its age instead of vanishing when the
    /// turn ended. The route that used to be `discarded` for every read —
    /// first for every read of any world, then for every read of an EYELESS
    /// world while `AmbientWorld` was only the three watched apps.
    case registered
    /// It succeeded, joined inside the grace, and reached nobody.
    ///
    /// RETIRED WITH IT: `spokenInTurn` — "the lane read it, joined in-turn,
    /// and a grounded pass spoke it". That grounded pass (`speakInTurnRead`)
    /// is gone by the user's decision: it held the turn open for a second
    /// network round trip after the audio had drained. Nothing can produce
    /// that route any more, and a diagnostic pane must never offer a
    /// vocabulary word for something that cannot happen — so the case is
    /// deleted rather than left standing as decoration.
    ///
    /// Which leaves THIS row for the reads that genuinely land nowhere — a
    /// primitive (`run_shell`, `run_applescript`) whose owner no world claims,
    /// a summary with nothing in it.
    ///
    /// IT USED TO MEAN SOMETHING FAR WORSE, and the sentence that stood here
    /// is worth keeping as a warning: "a world the ambient store has no eyes
    /// for (calendar, files, mail) has no `(world, slot)` to key a fact on, so
    /// its read really does reach nobody." That was true, and it was the
    /// regression — a truthfully-reported hole is still a hole. Every plugin
    /// owner is an `AmbientWorld` now, so a calendar read routes `registered`
    /// exactly as a Pages read does. `prefetched` covers anything the user
    /// asked to hear this turn; `registered` covers a read reaching the next.
    case discarded
    /// The follow-up carrying it is FINISHED but cannot speak yet: its
    /// originating exchange is no longer on screen, so it may not cut into a
    /// newer reply. It is waiting for a genuinely quiet room.
    ///
    /// WHY THIS ROW EXISTS. `finishRoutine` records `.spokenDetached` the
    /// moment it hands a read to the follow-up chain — optimistically, BEFORE
    /// a word is spoken. When the speech was then held or dropped, the ledger
    /// still claimed "detached read → voice": a delivery failure wearing a
    /// success's clothes, which is the exact class of blind spot this whole
    /// file was written to close. A stall is a state now, not a silence.
    case heldForQuiet
    /// …and the moment passed. Dropped rather than spoken into the wrong
    /// context — the user's rule: "if the moment has passed it is DROPPED
    /// rather than spoken into the wrong context." The transcript still shows
    /// it under its own exchange; only the EAR misses it.
    ///
    /// TWO PRODUCERS, ONE OUTCOME. The follow-up floor is the first. The second
    /// is a routine's spoken PROGRESS MARK, dropped by `VoicePipeline
    /// .speakRoutineProgress` because the room was not quiet — a gate that is
    /// hard, silent and ONE-SHOT, so the mark is consumed forever with no retry
    /// and, until `MaryBrain.noteProgressDropped`, no trace at all. A routine
    /// that lost both of its marks could sit silent from 0 to 420 s with
    /// nothing anywhere recording that two spoken promises had been destroyed.
    /// The timing was the user's decision and is unchanged; the invisibility
    /// was not. `detail` names which it was ("progress mark — …").
    case droppedStale
    /// THE WATCHDOG KILLED IT. A detached routine ran past its wall-clock cap
    /// and the lane was cancelled with nothing to report.
    ///
    /// THE FAILURE THIS MAKES VISIBLE (confirmed against a live user session):
    /// `expireRoutine` cancelled, cleared and yielded `.routineSettled` —
    /// speaking nothing, merging nothing, enqueueing nothing. The
    /// `ProactiveEvent` doc comment admitted it in as many words: "the watchdog
    /// expired a hung one… nothing is spoken." A user waited out the whole cap
    /// and got silence, with no row anywhere saying an answer had been
    /// destroyed. Expiry speaks an honest line now, and it says so here.
    case expiredUnanswered
    /// SUPERSEDED, AND STILL WORTH SOMETHING. The user moved on while a read
    /// was running, so its result may not cut into the newer exchange — but the
    /// read SUCCEEDED, and the user's rule is explicit: "The transcript still
    /// shows it under its own exchange."
    ///
    /// THE FAILURE THIS MAKES VISIBLE (confirmed against a live user session):
    /// every new turn marked every running routine superseded, and the
    /// silent-settle arm then returned without speaking — so asking about the
    /// calendar and then saying anything else at all (or an ASR fire on a
    /// cough) discarded a completed, all-ok calendar answer forever. Asking
    /// again worked, which is precisely what the user reported. Superseded ≠
    /// worthless: the passage goes to the transcript under its own exchange and
    /// the floor decides about the ear.
    case supersededToTranscript
    /// THE FOLLOW-UP CHAIN GAVE WAY. Either a chain entry stopped waiting for a
    /// wedged predecessor, or a body ran past its own budget and degraded to
    /// the deterministic line.
    ///
    /// THE FAILURE THIS MAKES VISIBLE (confirmed against a live user session):
    /// `enqueueFollowUp` had no timeout, no cancellation and no reset, so one
    /// body that never returned blocked every later follow-up permanently —
    /// across turns, across topics, across applications — and blocked its
    /// caller too, so the "still working" chip never went dark. NOT a failure
    /// row: order was sacrificed so the answer could keep moving, and something
    /// was delivered. It is here so the wedge is named at a glance instead of
    /// costing another trace.
    case chainStalled

    public var displayName: String {
        switch self {
        case .prefetched:     return "pre-read → voice"
        case .spokenDetached: return "detached read → voice"
        case .registered:     return "read → ambient store (next turn holds it)"
        case .discarded:      return "read discarded — reached nobody"
        case .heldForQuiet:   return "follow-up held — waiting for a quiet room"
        case .droppedStale:   return "follow-up dropped — the moment had passed"
        case .expiredUnanswered:
            return "routine expired — the watchdog stopped waiting"
        case .supersededToTranscript:
            return "superseded read → transcript only (not spoken)"
        case .chainStalled:
            return "follow-up chain stalled — the queue moved on without it"
        }
    }

    /// True when the read's text actually reached the speaking lane — this
    /// turn's, or (for `registered`) the next one's. `heldForQuiet` is still
    /// on its way; the FAILURES are the ones that answer "no".
    public var reachedVoice: Bool { !Self.failures.contains(self) }

    /// The routes that mean the text did not reach the ear. Named once so a
    /// pane, a report and a test cannot disagree about which rows are bad.
    ///
    /// `supersededToTranscript` sits here for the same reason `droppedStale`
    /// does: both are CORRECT policy decisions, and both mean the user did not
    /// hear it. A pane that called a deliberate silence a success would be the
    /// same blind spot this file exists to close. `chainStalled` is deliberately
    /// absent — a stalled chain still delivers, late or out of order.
    public static let failures: Set<ReadRoute> = [
        .discarded, .droppedStale, .expiredUnanswered, .supersededToTranscript,
    ]
}

public struct ReadDelivery: Sendable, Equatable {
    public var route: ReadRoute
    /// The Skills that produced it, or the pre-read's phrase for `prefetched`.
    public var detail: String
    /// How much text was delivered — an 1800-character region clamped to 500
    /// is a delivery failure wearing a success's clothes.
    public var characters: Int
    public var at: Date

    public init(route: ReadRoute, detail: String, characters: Int, at: Date = Date()) {
        self.route = route
        self.detail = detail
        self.characters = characters
        self.at = at
    }

    /// The debugger's one-line phrasing.
    public var summary: String {
        var line = route.displayName
        if !detail.isEmpty { line += " — \(detail)" }
        if characters > 0 { line += " (\(characters) chars)" }
        return line
    }
}

public final class ReadDeliveryLedger: @unchecked Sendable {

    public static let shared = ReadDeliveryLedger()

    private let box = OSAllocatedUnfairLock<ReadDelivery?>(initialState: nil)

    public init() {}

    public func record(_ delivery: ReadDelivery) {
        box.withLock { $0 = delivery }
    }

    public func latest() -> ReadDelivery? {
        box.withLock { $0 }
    }

    /// Test isolation — the process-wide box must never leak between suites.
    public func clear() {
        box.withLock { $0 = nil }
    }
}
