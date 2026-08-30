//
//  RouteTraceViewModel.swift
//  Mary
//
//  WHAT: Routes pane data — 1 Hz poll, impure gather(), pure build(_:).
//  OUT:  RouterPaneView
//  PIN:  Equatable diff before republish; never Granite @Store.
//

import MaryAmbient
import MaryBrain
import Foundation

/// One turn, flattened for display.
struct RouteRow: Identifiable, Equatable {
    var id: UUID
    var date: Date
    var utterance: String

    var intent: AmbientIntent
    var decidedBy: AmbientSignal
    var rankingMode: AmbientRankingMode
    var gate: AmbientIntentGate
    var world: AmbientWorld?
    var writingTarget: AmbientWritingTarget?
    var supportingContext: String?

    var lead: AmbientAttention?
    /// WHERE the turn led, as one value — the native world or the Dynamic
    /// application. `lead` stays alongside it for the report's fallback
    /// spelling on rows recorded before places existed.
    var leadPlace: AmbientPlace?
    /// The user turn this route resolved — the chat-side join key.
    var exchangeID: UUID?
    var namedPlaces: [AmbientPlace]
    /// Sorted for stable display — `Set` iteration order is not.
    var candidateAttentions: [AmbientAttention]

    var needsLocate: Bool
    var needsPreRead: Bool
    var needsExecution: Bool

    var verdicts: AmbientVerdicts

    var systemPromptChars: Int
    var registryRevision: UUID
    var packageIDs: [PackageID]
    var exposedSkillCount: Int
    var abilityRoster: AbilityRosterTrace
    var skillRuns: [SkillRunReceipt]

    /// Age, for the row header.
    func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(date)) }
}

/// One decision of either kind, merged in time order (not sectioned).
enum RouterEntry: Identifiable, Equatable {
    case turn(RouteRow)

    var id: UUID {
        switch self {
        case .turn(let row): return row.id
        }
    }

    var date: Date {
        switch self {
        case .turn(let row): return row.date
        }
    }
}

@MainActor
final class RouteTraceViewModel: ObservableObject {

    @Published private(set) var rows: [RouteRow] = []
    @Published private(set) var entries: [RouterEntry] = []

    private var pollTask: Task<Void, Never>?

    /// Everything `build` reads. Impure collection stays in `gather()`.
    struct Inputs {
        var records: [AmbientTraceRecord] = []
        var now: Date = Date()
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
        let inputs = Self.gather()
        let built = Self.build(inputs)
        // Equatable diff — a quiet second must not repaint the pane.
        if built != rows { rows = built }
        let merged = Self.buildEntries(inputs)
        if merged != entries { entries = merged }
    }

    // MARK: - Impure

    private static func gather() -> Inputs {
        Inputs(
            records: AmbientTraceLog.shared.entries(),
            now: Date())
    }

    // MARK: - Pure

    /// `nonisolated` because it is pure — the same declaration
    /// `PerceptionSnapshotViewModel.buildCards` carries, and what lets the
    /// pane be table-tested from XCTest without hopping to the main actor.
    nonisolated static func build(_ inputs: Inputs) -> [RouteRow] {
        inputs.records.map { record in
            let route = record.route
            return RouteRow(
                id: record.id,
                date: record.date,
                utterance: record.utterance,
                intent: route.intent,
                decidedBy: route.decidedBy,
                rankingMode: route.rankingMode,
                gate: route.gate,
                world: route.world,
                writingTarget: route.writingTarget,
                supportingContext: route.supportingContext,
                leadPlace: route.leadPlace,
                exchangeID: record.exchangeID,
                namedPlaces: route.namedPlaces.sorted { $0.token < $1.token },
                candidateAttentions: route.candidateAttentions.sorted { $0.rawValue < $1.rawValue },
                needsLocate: route.needsLocate,
                needsPreRead: route.needsPreRead,
                needsExecution: route.needsExecution,
                verdicts: route.verdicts,
                systemPromptChars: record.systemPromptChars,
                registryRevision: record.registryRevision,
                packageIDs: record.packageIDs,
                exposedSkillCount: record.exposedSkillCount,
                abilityRoster: record.abilityRoster,
                skillRuns: record.skillRuns)
        }
    }

    /// Pure/nonisolated; newest first, matching the ring buffers.
    nonisolated static func buildEntries(_ inputs: Inputs) -> [RouterEntry] {
        // ONE KIND OF ENTRY. A second arm carried unprompted remarks, whose
        // lane is not in this cut; the merge and the sort stay because the
        // shape is right and a second kind of row is what returns with it.
        build(inputs).map { RouterEntry.turn($0) }.sorted { $0.date > $1.date }
    }
}
