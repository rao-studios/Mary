//
//  BehavioralAssembler.swift
//  MaryBrain
//
//  THE THING THAT KNOWS WHICH TURN AN ACTION BELONGS TO.
//
//  One episode is one USER TURN: the query, the ambient context that was
//  actually injected for it, and every action that turn produced. This holds
//  the open one, takes records as they settle, and hands the finished episode
//  to whatever is recording.
//
//  A LOCK-BOXED CLASS, NOT AN ACTOR. Records arrive from synchronous lane
//  emits — a veto refusing a call, a deterministic press — and an actor would
//  push `await` into every one of those sites. The state is four small fields
//  behind one lock; making the whole turn loop asynchronous to protect them
//  would be a poor trade.
//
//  STAGE AND CLAIM, mirroring `RetrievalTraceLedger`, and for the identical
//  reason: the system-prompt provider is zero-arg (`@Sendable () -> String`),
//  so it cannot name the turn it is building for. Threading an id through that
//  seam would widen a closure five installs share for one observer's benefit.
//  The provider stages the capture; the turn loop claims it onto the episode
//  it opens a few statements later. Single producer, single consumer, both on
//  the brain actor — a stage can never belong to any turn but the one that
//  claims next, and a stale stage is DISCARDED rather than attached, because a
//  row lying about which query earned its context is worse than a thin row.
//
//  NOTHING IS EVER DELETED. Episodes are a record of what was DONE, and an
//  action that ran is a fact about the world whether the turn that ordered it
//  was cancelled, superseded, or completed. Every seal carries a reason, and
//  filtering on that reason is the reader's job.
//

import Foundation
import MaryFoundation
import os

public final class BehavioralAssembler: @unchecked Sendable {

    private struct Open {
        var episode: BehavioralEpisode
        /// Detached routines that must settle before this episode may seal.
        var pendingRoutines: Int = 0
        /// A seal asked for while routines were still running.
        var deferredSeal: EpisodeSealReason?
    }

    private let box = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var open: Open?
        var stagedCapture: AmbientCapture?
        /// Records that arrived for an episode already sealed, or for none —
        /// counted, not kept. See `droppedRecords`.
        var dropped: Int = 0
    }

    private let recorder: (any BehavioralRecording)?

    /// Same shape as `MaryBrain.laneLog`: short info sentences, one Console
    /// category for the whole episode lifecycle (assembler → Totem → Life).
    package static let behavioralLog = Logger(subsystem: "nyc.rao.mary", category: "behavior")

    public init(recorder: (any BehavioralRecording)? = nil) {
        self.recorder = recorder
    }

    /// First UUID group, lowercase — greppable without dumping the full id.
    package static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - The input half

    /// Stage the capture built during this turn's prompt construction.
    ///
    /// A SECOND STAGE REPLACES THE FIRST. Two prompt builds with no episode
    /// opened between them means the first turn never got off the ground; its
    /// capture describes a query that was never asked.
    public func stageCapture(_ capture: AmbientCapture) {
        box.withLock { $0.stagedCapture = capture }
        let count = capture.facts.count
        let line = count == 0
            ? "staged capture — empty"
            : "staged capture — \(count) fact\(count == 1 ? "" : "s")"
        Self.behavioralLog.info("\(line, privacy: .public)")
    }

    /// Attach the staged capture to the open episode.
    ///
    /// The stage is cleared EVEN WHEN there is no episode to attach it to —
    /// see the header on why a stale stage is dropped rather than kept.
    public func claimStagedCapture(forEpisode id: UUID) {
        enum Claim { case none, claimed, noOpen, wrongEpisode }
        let outcome: Claim = box.withLock { state in
            guard let capture = state.stagedCapture else { return .none }
            state.stagedCapture = nil
            guard state.open != nil else { return .noOpen }
            guard state.open?.episode.id == id else { return .wrongEpisode }
            state.open?.episode.input.ambient = capture
            return .claimed
        }
        switch outcome {
        case .none: break
        case .claimed:
            Self.behavioralLog.info("claimed capture")
        case .noOpen:
            Self.behavioralLog.info("dropped staged capture — no open episode")
        case .wrongEpisode:
            Self.behavioralLog.info("dropped staged capture — wrong episode")
        }
    }

    /// Stamp Ability Totem targets once the turn's route exists. Empty
    /// targets skip Totem Ability — the episode is not kept.
    public func noteAbilityTargets(
        _ targets: [AbilityTotemTarget], forEpisode id: UUID
    ) {
        let applied: Bool = box.withLock { state in
            guard state.open?.episode.id == id else { return false }
            state.open?.episode.abilityTargets = Array(Set(targets)).sorted()
            return true
        }
        let line: String
        if !applied {
            line = "targets ignored — episode not open"
        } else if targets.isEmpty {
            line = "targets none — Totem will skip"
        } else {
            let listed = targets.map {
                "\($0.abilityID.rawValue)/\($0.paradigm.rawValue)"
            }.joined(separator: ", ")
            line = "targets \(listed)"
        }
        Self.behavioralLog.info("\(line, privacy: .public)")
    }

    // MARK: - Lifecycle

    /// Open the episode for one user turn.
    ///
    /// AN OPEN EPISODE FOUND HERE IS SEALED `.superseded`, not dropped. It
    /// reaches this state on the amend path, which yields no event of its own
    /// — the turn is simply replaced — and whatever it already did really
    /// happened.
    public func openEpisode(
        id: UUID,
        query: String,
        priorEpisodeID: UUID? = nil,
        provenance: EpisodeProvenance,
        at date: Date = Date()
    ) {
        let superseded: BehavioralEpisode? = box.withLock { state -> BehavioralEpisode? in
            var replaced: BehavioralEpisode?
            if var previous = state.open, previous.episode.id != id {
                previous.episode.seal(.superseded, at: date)
                replaced = previous.episode
            }
            // A NEW TURN'S CAPTURE HAS NOT BEEN BUILT YET. Anything staged is
            // from the turn being replaced.
            state.stagedCapture = nil
            state.open = Open(episode: BehavioralEpisode(
                id: id,
                openedAt: date,
                input: BehavioralInput(query: query, priorEpisodeID: priorEpisodeID),
                provenance: provenance))
            return replaced
        }
        if let superseded {
            let count = superseded.output.actions.count
            let line = "superseded \(Self.shortID(superseded.id)) — \(count) action\(count == 1 ? "" : "s"), handed off"
            Self.behavioralLog.info("\(line, privacy: .public)")
            hand(off: superseded)
        }
        let clipped = Self.clippedQuery(query)
        let opened = "opened \(Self.shortID(id)) — \"\(clipped)\" engine=\(provenance.engine) lane=\(provenance.lane)"
        Self.behavioralLog.info("\(opened, privacy: .public)")
    }

    /// Record one settled action.
    ///
    /// - Parameter episodeID: nil means the open episode. A detached routine
    ///   passes its ORIGIN id explicitly, because it may well land after the
    ///   turn that started it has been replaced by another — and its work
    ///   belongs to the turn that ordered it.
    public func append(_ record: BehavioralActionRecord, toEpisode episodeID: UUID? = nil) {
        let kept: Bool = box.withLock { state in
            guard var open = state.open,
                  episodeID == nil || episodeID == open.episode.id
            else {
                state.dropped += 1
                return false
            }
            open.episode.output.actions.append(record)
            state.open = open
            return true
        }
        let via = record.action.skill.skillID.rawValue
        let line: String
        if kept {
            line = "action \(record.action.intention) \(record.disposition.rawValue) via \(via)"
        } else {
            line = "dropped action \(record.action.intention) — no open episode"
        }
        Self.behavioralLog.info("\(line, privacy: .public)")
    }

    /// A routine detached from this turn and will settle later.
    public func noteRoutineDetached(origin: UUID) {
        let pending: Int? = box.withLock { state in
            guard state.open?.episode.id == origin else { return nil }
            state.open?.pendingRoutines += 1
            return state.open?.pendingRoutines
        }
        if let pending {
            Self.behavioralLog.info("routine detached, pending \(pending)")
        } else {
            Self.behavioralLog.info("routine detach ignored — episode not open")
        }
    }

    /// A detached routine finished. The LAST one out seals an episode whose
    /// seal was deferred — which is what makes "a routine's records land in
    /// the episode that started it" true rather than aspirational.
    public func noteRoutineSettled(origin: UUID, at date: Date = Date()) {
        enum Settle {
            case ignored
            case pending(Int)
            case sealed(BehavioralEpisode)
        }
        let outcome: Settle = box.withLock { state in
            guard var open = state.open, open.episode.id == origin else { return .ignored }
            open.pendingRoutines = max(0, open.pendingRoutines - 1)
            guard open.pendingRoutines == 0, let reason = open.deferredSeal else {
                state.open = open
                return .pending(open.pendingRoutines)
            }
            open.episode.seal(reason, at: date)
            state.open = nil
            return .sealed(open.episode)
        }
        switch outcome {
        case .ignored:
            Self.behavioralLog.info("routine settle ignored — episode not open")
        case .pending(let count):
            Self.behavioralLog.info("routine settled, pending \(count)")
        case .sealed(let episode):
            Self.behavioralLog.info("routine settled, pending 0")
            Self.behavioralLog.info("\(Self.sealedLine(episode), privacy: .public)")
            hand(off: episode)
        }
    }

    /// Seal the episode.
    ///
    /// DEFERRED WHILE ROUTINES RUN. A turn that kicked off background work is
    /// not finished when the spoken reply ends; sealing there would file the
    /// routine's own actions under whatever turn came next. The brain's
    /// routine watchdog guarantees every detached routine terminates, so the
    /// deferral cannot outlive the process.
    public func seal(
        _ id: UUID, reason: EpisodeSealReason, at date: Date = Date()
    ) {
        enum Seal {
            case missing
            case deferred(Int)
            case ready(BehavioralEpisode)
        }
        let outcome: Seal = box.withLock { state in
            guard var open = state.open, open.episode.id == id else { return .missing }
            guard open.pendingRoutines == 0 else {
                open.deferredSeal = reason
                state.open = open
                return .deferred(open.pendingRoutines)
            }
            open.episode.seal(reason, at: date)
            state.open = nil
            return .ready(open.episode)
        }
        switch outcome {
        case .missing:
            let line = "seal ignored \(Self.shortID(id)) — episode not open"
            Self.behavioralLog.info("\(line, privacy: .public)")
        case .deferred(let pending):
            let line = "seal deferred \(Self.shortID(id)) — \(pending) routine\(pending == 1 ? "" : "s") in flight"
            Self.behavioralLog.info("\(line, privacy: .public)")
        case .ready(let episode):
            Self.behavioralLog.info("\(Self.sealedLine(episode), privacy: .public)")
            hand(off: episode)
        }
    }

    /// Seal whatever is open, whoever it belongs to — the quit path.
    ///
    /// IN-FLIGHT ACTIONS ARE ALREADY `.unsettled` by construction: a record is
    /// composed once, when its dispatch returns, so an action still running at
    /// quit has no record at all rather than a wrong one. What this saves is
    /// everything that DID settle before the signal.
    public func flushOpenEpisodes(
        reason: EpisodeSealReason = .appQuit, at date: Date = Date()
    ) {
        let ready: BehavioralEpisode? = box.withLock { state -> BehavioralEpisode? in
            guard var open = state.open else { return nil }
            open.episode.seal(reason, at: date)
            state.open = nil
            return open.episode
        }
        if let ready {
            Self.behavioralLog.info("\(Self.sealedLine(ready), privacy: .public)")
            hand(off: ready)
        }
    }

    // MARK: - Diagnostics

    /// Records that arrived with nowhere to go. A non-zero count is a wiring
    /// bug, and counting it is how the probe can say so.
    public var droppedRecords: Int { box.withLock(\.dropped) }

    /// The open episode's id, for the sites that need to name it.
    public var openEpisodeID: UUID? { box.withLock { $0.open?.episode.id } }

    /// What the open episode currently holds — Life and codec acting read this
    /// without taking ownership of the turn.
    public func openSnapshot() -> (
        id: UUID, input: BehavioralInput, targets: [AbilityTotemTarget]
    )? {
        box.withLock { state in
            guard let open = state.open else { return nil }
            return (open.episode.id, open.episode.input, open.episode.abilityTargets)
        }
    }

    // MARK: - Internals

    private func hand(off episode: BehavioralEpisode) {
        let id = Self.shortID(episode.id)
        guard let recorder else {
            let line = "handoff skipped \(id) — no recorder"
            Self.behavioralLog.info("\(line, privacy: .public)")
            return
        }
        let line = "handoff \(id)"
        Self.behavioralLog.info("\(line, privacy: .public)")
        // DETACHED, because sealing happens on the turn loop's own path and a
        // slow disk must not lengthen the pause before Mary speaks again.
        Task.detached(priority: .utility) {
            await recorder.append(episode)
        }
    }

    private static func clippedQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    private static func sealedLine(_ episode: BehavioralEpisode) -> String {
        let reason = episode.sealedReason?.rawValue ?? "unsealed"
        let count = episode.output.actions.count
        let duration: String
        if let sealed = episode.sealedAt {
            duration = String(format: "%.1fs", sealed.timeIntervalSince(episode.openedAt))
        } else {
            duration = "—"
        }
        return "sealed \(shortID(episode.id)) \(reason) — \(count) action\(count == 1 ? "" : "s"), \(duration)"
    }
}
