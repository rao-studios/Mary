//
//  ReadDeliveryLedger.swift
//  MaryBrain
//
//  WHAT: Did the last READ reach the lane that speaks?
//  IN:   finishRoutine / seerTurn join
//  OUT:  last-value debugger row
//  PIN:  Last-value box, not a log — action log already keeps history.
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
    /// It succeeded, joined inside the grace, and the AMBIENT CONTEXT STORE took it: registered as a `(world, namedRead:)` fact
    case registered
    /// It succeeded, joined inside the grace, and reached nobody.
    /// PIN: RETIRED WITH IT: `spokenInTurn` — "the lane read it, joined in-turn, and a grounded pass spoke it".
    case discarded
    /// The follow-up carrying it is FINISHED but cannot speak yet: its originating exchange is no longer on screen, so it may not cut into a newer reply.
    case heldForQuiet
    /// …and the moment passed. Dropped rather than spoken into the wrong context
    case droppedStale
    /// THE WATCHDOG KILLED IT. A detached routine ran past its wall-clock cap and the lane was cancelled with nothing to report.
    case expiredUnanswered
    /// SUPERSEDED, AND STILL WORTH SOMETHING. The user moved on while a read was running, so its result may not cut into the newer exchange
    case supersededToTranscript
    /// THE FOLLOW-UP CHAIN GAVE WAY. Either a chain entry stopped waiting for a wedged predecessor
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

    /// The routes that mean the text did not reach the ear. Named once so a pane, a report and a test cannot disagree about which rows are bad.
    /// PIN: `supersededToTranscript` sits here for the same reason `droppedStale` does: both are CORRECT policy decisions
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
