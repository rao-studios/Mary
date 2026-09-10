//
//  PerceptionSnapshotViewModel+Inputs.swift
//  Mary
//
//  WHAT: Everything builders read, as parameters. One row per place (not compiled slots).
//  OUT:  PerceptionSnapshotViewModel.build*
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryRuntime

extension PerceptionSnapshotViewModel {

    struct Inputs {

        /// One observed place, as the debugger found it.
        struct Observed {
            var world: PerceptionWorld
            /// Is the application running at all?
            var isRunning = false
            /// Is its observer polling?
            var isActive = false
            /// What it said this turn — the FULL section, when it has one.
            var contribution: String?
            /// Extra lines from other observers watching the same place.
            var extraContributions: [PerceptionCard.Field] = []
            var capturedAt: Date?
            var lastSuccessAt: Date?
            var lastError: String?
            /// Accessibility refused, or the application is unreadable.
            var blindness: PerceptionCard.Blindness?
            var pollDescription = "on demand"
        }

        var observed: [Observed] = []
        var axTrusted = false

        /// The live focus picture, mirrored from the same tracker the turn
        /// loop reads — never a second copy computed here.
        var ambient: WorkspaceFocus?
        var effective: WorkspaceFocus?
        var writingPlace: AmbientPlace?
        var pinned: PinnedWorld?
        var writingInPlay = true
        var overrideActive = false

        var surfaces: [AmbientPlace: AmbientSurface] = [:]
        var facts: [AmbientFact] = []
        var readDelivery: ReadDelivery?
        var rankingMode: AmbientRankingMode = .relevance
        var now: Date = .init()

        func ambientSurface(for world: PerceptionWorld) -> AmbientSurface? {
            surfaces[world.place]
        }

        func ambientFacts(for world: PerceptionWorld) -> [AmbientFact] {
            facts.filter { $0.place == world.place }
        }

        /// The places that CONTRIBUTED, which is not the same as the places
        /// that are running — the distinction the whole focus arbitration
        /// turns on, mirrored here so the pane cannot disagree with it.
        var contributing: [Observed] {
            observed.filter { $0.contribution != nil }
        }
    }
}
