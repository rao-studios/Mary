//
//  PerceptionSnapshotViewModel+Inputs.swift
//  Mary
//
//  EVERYTHING THE BUILDERS READ, AS PARAMETERS.
//
//  The builders never touch a singleton, which is what lets the whole
//  classification pin under test: a pane that lies about which place led is a
//  pane you cannot debug WITH, and the only way to know it does not is to be
//  able to state a world and check the answer.
//
//  ONE ROW PER PLACE, and the count is not compiled. Its predecessor had a
//  named field group per application — an IDE's context, denial flag, active
//  flag, last error, last success, running flag, three contribution strings,
//  then the same again for three editors and a presentation app, plus one
//  open-ended list for anything taught. Sixty-odd fields answering the same
//  six questions about six things somebody had thought of.
//
//  A PANE WITH A SLOT FOR EXACTLY ONE MANUSCRIPT APPLICATION cannot draw the
//  second one a user installs, and an undrawn watched application is the pane
//  failing at its only job. So the rows arrive as a list.
//

import AppKit
import Foundation
import MaryAdapters
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
