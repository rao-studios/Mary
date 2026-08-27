//
//  RealmLensProvider.swift
//  Mary
//
//  WHICH REALM LED EACH CHAT TURN — the transcript's half of the Routes
//  pane's story. `RouteTraceViewModel`'s shape exactly: a 1 Hz poll of the
//  lock-boxed `AmbientTraceLog`, one impure `gather()`, a PURE `build(_:)`
//  over an `Inputs` value, and an Equatable diff before republishing so a
//  quiet second repaints nothing.
//
//  The lens reads LIVE state only. Nothing here persists into the transcript
//  model: a restored conversation, or a row older than the trace log's ring
//  (50 turns), simply resolves no entry and shows no capsule.
//

import MaryBrain
import Foundation
import MaryRuntime

/// One resolved exchange: the place that led it, and the trace row that
/// says so (kept so a future affordance can deep-link the Routes pane).
struct RealmLensEntry: Equatable {
    var leadPlace: AmbientPlace?
    /// Places with fresh evidence beside the lead at exchange time, and
    /// which of them were only glanced — the merged-worlds chip's data.
    var coActivePlaces: [AmbientPlace] = []
    var glancedPlaces: Set<AmbientPlace> = []
    var traceID: UUID
}

@MainActor
final class RealmLensProvider: ObservableObject {

    /// Keyed by exchange id — the user turn's `BrainTurn.id`, the same id
    /// `TranscriptOps` stamps onto the bubble as `turnID`. Only records that
    /// carry the join key appear at all.
    @Published private(set) var entries: [UUID: RealmLensEntry] = [:]

    private var pollTask: Task<Void, Never>?

    /// Everything `build` reads. Impure collection stays in `gather()`.
    struct Inputs {
        var records: [AmbientTraceRecord] = []
    }

    func start() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() {
        let built = Self.build(Self.gather())
        // Equatable diff — a quiet second must not repaint the transcript.
        if built != entries { entries = built }
    }

    // MARK: - Impure

    private static func gather() -> Inputs {
        Inputs(records: AmbientTraceLog.shared.entries())
    }

    // MARK: - Pure

    /// `nonisolated` because it is pure — the same declaration its sibling
    /// `RouteTraceViewModel.build` carries, so the join is table-testable
    /// from XCTest without hopping to the main actor. Records arrive newest
    /// first; the newest row for an exchange wins (a superseding resubmit
    /// records again under the same id).
    nonisolated static func build(_ inputs: Inputs) -> [UUID: RealmLensEntry] {
        var built: [UUID: RealmLensEntry] = [:]
        for record in inputs.records {
            guard let exchangeID = record.exchangeID,
                  built[exchangeID] == nil else { continue }
            built[exchangeID] = RealmLensEntry(
                leadPlace: record.route.leadPlace,
                coActivePlaces: record.coActivePlaces,
                glancedPlaces: record.glancedPlaces,
                traceID: record.id)
        }
        return built
    }
}
