//
//  MediaTransportCache.swift
//  MaryPlugin
//
//  WHAT: The last transport reading, served instantly; refreshed off the turn.
//  IN:   MediaSurfaceAdapter.turnPerceptions
//  OUT:  MediaSurfaceAX.Reading? — never a walk on the caller's thread
//  PIN:  A TRANSPORT READ IS NOT WORTH A TURN. `turnPerceptions()` runs on
//        EVERY turn, and it used to walk the player's whole Accessibility tree
//        inline. MEASURED on Apple Music showing a playlist: 820 nodes at
//        ~31ms each — 25 SECONDS, twice, inside a turn whose own budget could
//        not cut it short. The browser beside it read in 104ms.
//        The per-node cost is the player's AX server answering, so no budget
//        preset fixes it: a tighter walk is the same cost per node over fewer
//        nodes, and the transport lives past most of them. The only thing that
//        works is not doing it while someone waits.
//  PIN:  STALE IS THE RIGHT ANSWER HERE. What is playing changes on a human
//        timescale, and a reading from a few seconds ago is worth far more to
//        the prompt than a turn that stalls for half a minute to be current.
//        A refresh already in flight is never stacked — one walk at a time per
//        process, the same coalescing `AmbientSurfaceObserver` uses.
//
import Foundation
import MaryComputerUse
import os

/// Serves the last known transport for a player and refreshes it in the
/// background. Never walks on the caller's thread.
public final class MediaTransportCache: @unchecked Sendable {

    public static let shared = MediaTransportCache()

    /// Older than this and a refresh is kicked — but the stale reading is still
    /// served, because the alternative is publishing nothing at all.
    public static let freshHorizon: TimeInterval = 10

    private struct Entry {
        var reading: MediaSurfaceAX.Reading?
        var readAt: Date
        /// A walk is in flight for this process. One at a time: on a slow
        /// player a second would queue behind the first and read the same tree.
        var refreshing: Bool
        /// What the last completed read of THIS player cost. The cache learns
        /// whether a player is worth waiting for rather than assuming.
        var lastReadMs: UInt64?
    }

    /// A player that answered slower than this is never read synchronously
    /// again — the wait would outlast a Skill's own dispatch budget and end in
    /// a timeout, which is worse than saying so immediately.
    /// MEASURED: Apple Music with a playlist showing reads in ~25s; the
    /// dispatch budget is 20s, so a cold blocking read there could only ever
    /// fail. A player that reads in 200ms should still be waited for.
    public static let worthWaitingForMs: UInt64 = 3_000

    private let entries = OSAllocatedUnfairLock<[pid_t: Entry]>(initialState: [:])

    private static let log = Logger(
        subsystem: "nyc.rao.mary", category: "turns")

    private init() {}

    /// The last reading for this player, kicking a background refresh when it
    /// has aged out.
    ///
    /// - Parameter readingColdSynchronously: what to do when NOTHING has been
    ///   read yet. `false` — the turn path — returns nil and warms in the
    ///   background, because a perception is worth zero turns. `true` — a
    ///   person who explicitly asked what is playing — pays the walk once, and
    ///   leaves it warm for everyone after. A cold miss is the ONLY case where
    ///   this blocks; a stale hit never does.
    ///
    /// PIN: A COLD READ IGNORES `refreshing`, and that is not an oversight.
    ///  `turnPerceptions()` runs first on every turn and marks the entry
    ///  refreshing before any Skill is dispatched, so an in-flight background
    ///  walk is the NORMAL state by the time `now_playing` asks. Gating the
    ///  synchronous read on that flag made the first "what's playing" of every
    ///  session answer "I couldn't read the player just now" — measured, twice.
    ///  Worst case the two reads overlap; the later one wins and both are true.
    public func reading(
        pid: pid_t,
        registration: MediaSurfaceRegistration,
        readingColdSynchronously: Bool = false
    ) -> MediaSurfaceAX.Reading? {
        let now = Date()
        let (cached, shouldRefresh) = entries.withLock { state -> (MediaSurfaceAX.Reading?, Bool) in
            guard let entry = state[pid] else {
                state[pid] = Entry(reading: nil, readAt: .distantPast, refreshing: true)
                return (nil, true)
            }
            let stale = now.timeIntervalSince(entry.readAt) >= Self.freshHorizon
            guard stale, !entry.refreshing else { return (entry.reading, false) }
            state[pid]?.refreshing = true
            return (entry.reading, true)
        }
        // Nothing known AND asked for outright: read it here, so the first
        // "what's playing" of a session answers instead of apologising —
        // unless this player has already proved it is too slow to wait for.
        // The lock is NOT held across the walk.
        let knownSlow = entries.withLock { state in
            (state[pid]?.lastReadMs ?? 0) > Self.worthWaitingForMs
        }
        if cached == nil, readingColdSynchronously, !knownSlow {
            let started = DispatchTime.now()
            let fresh = MediaSurfaceAX.read(pid: pid, registration: registration)
            let ms = (DispatchTime.now().uptimeNanoseconds
                &- started.uptimeNanoseconds) / 1_000_000
            entries.withLock { state in
                state[pid] = Entry(
                    reading: fresh, readAt: Date(), refreshing: false, lastReadMs: ms)
            }
            return fresh
        }
        if shouldRefresh { refresh(pid: pid, registration: registration) }
        return cached
    }

    /// How long a receipt read may hold a Skill while this cache is still
    /// learning what a player costs. The first read of a session pays this;
    /// every one after it is decided by `worthWaitingForMs` for free.
    public static let learningWaitSeconds: TimeInterval = 3

    /// A read taken NOW, or nil when this player costs more than the answer is
    /// worth — either proved already, or still running when the wait ran out.
    ///
    /// PIN: FOR RECEIPTS, WHICH A STALE READING CANNOT SERVE. `movement()`
    /// compares a before against an after to prove the transport moved; served
    /// from cache both halves would be the same reading and every act would
    /// report "nothing moved". So this never returns cached data — it either
    /// reads live or admits it cannot.
    /// Nil is already a first-class answer there: "could not be told", which
    /// `movement()` documents as distinct from "nothing moved" and must not be
    /// reported as failure. Volume and mute have always been unprovable this
    /// way. MEASURED: on Apple Music a receipt cost two ~25s reads around a
    /// keypress that itself takes microseconds, and blew the Skill's own 20s
    /// dispatch budget — so the act worked and Mary reported a timeout.
    /// PIN: BOUNDED, SO THE FIRST ONE IS NOT THE EXPENSIVE ONE. The cache can
    /// only learn a player is slow by reading it once, and charging 25s for
    /// that lesson is the very thing being fixed. The abandoned walk finishes
    /// on its own time and records what it cost, so the lesson is still learned
    /// — just not at anyone's expense.
    public func freshReadingIfAffordable(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> MediaSurfaceAX.Reading? {
        let knownSlow = entries.withLock { state in
            (state[pid]?.lastReadMs ?? 0) > Self.worthWaitingForMs
        }
        guard !knownSlow else { return nil }
        let entries = self.entries
        return await bounded(Self.learningWaitSeconds) {
            let started = DispatchTime.now()
            let fresh = MediaSurfaceAX.read(pid: pid, registration: registration)
            let ms = (DispatchTime.now().uptimeNanoseconds
                &- started.uptimeNanoseconds) / 1_000_000
            entries.withLock { state in
                state[pid] = Entry(
                    reading: fresh ?? state[pid]?.reading,
                    readAt: Date(), refreshing: false, lastReadMs: ms)
            }
            return fresh
        } ?? nil
    }

    /// Drop what is known about a player — a process that went away.
    public func invalidate(pid: pid_t) {
        entries.withLock { $0[pid] = nil }
    }

    /// Take a reading somebody else just paid for.
    ///
    /// PIN: THE RECEIPT READS FEED THIS. Driving the transport is followed by a
    /// fresh read to prove the act landed, and that read is the newest truth in
    /// the system — so it lands here rather than being thrown away, and "pause
    /// it" followed by "what's playing" answers with the state just created
    /// instead of a ten-second-old one.
    public func store(_ reading: MediaSurfaceAX.Reading, pid: pid_t) {
        entries.withLock { state in
            state[pid] = Entry(
                reading: reading, readAt: Date(), refreshing: false,
                lastReadMs: state[pid]?.lastReadMs)
        }
    }

    private func refresh(pid: pid_t, registration: MediaSurfaceRegistration) {
        // Detached and unawaited ON PURPOSE: the whole point is that no turn
        // is behind this. Utility priority so it yields to anything a person
        // is waiting on.
        Task.detached(priority: .utility) { [entries] in
            let started = DispatchTime.now()
            let fresh = MediaSurfaceAX.read(pid: pid, registration: registration)
            let ms = (DispatchTime.now().uptimeNanoseconds
                &- started.uptimeNanoseconds) / 1_000_000
            entries.withLock { state in
                // A read that failed keeps the previous answer rather than
                // blanking it: a player mid-relaunch is not a player stopped.
                state[pid] = Entry(
                    reading: fresh ?? state[pid]?.reading,
                    readAt: Date(),
                    refreshing: false,
                    lastReadMs: ms)
            }
            if ms >= 1000 {
                Self.log.info(
                    """
                    transport refresh — \(registration.applicationID, privacy: .public) \
                    \(ms, privacy: .public)ms, off the turn
                    """)
            }
        }
    }
}
