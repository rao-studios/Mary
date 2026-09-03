//
//  MaryBrain+TurnLog.swift
//  MaryBrain
//
//  WHAT: turnLog sentences for the Xcode / pair-coding circuit.
//  OUT:  Console.app category "turns"
//

import MaryAmbient
import MaryPlugin
import Foundation
import os

extension MaryBrain {

    /// Invocation names the perfect-world pair-coding path would call.
    static let codingCircuitSkills: [String] = [
        "current_file", "read_buffer", "read_selection", "read_symbol",
        "delegate_coding", "coding_start",
    ]

    func logTurnEntry(userText: String) {
        let cue = AmbientRanker.namedDiscipline(in: userText)?.rawValue ?? "none"
        let selection: String
        if let handoff = AmbientSelectionTurnContext.snapshot?.handoff {
            let subject = handoff.subject.map { " file=\($0)" } ?? ""
            selection = "selection handoff app=\(handoff.applicationID)\(subject)"
        } else {
            selection = "no selection handoff"
        }
        let line = "turn — \"\(userText)\" override=\(cue) \(selection)"
        Self.turnLog.info("\(line, privacy: .public)")
    }

    func logTurnExit(_ reason: String) {
        Self.turnLog.info("turn exited — \(reason, privacy: .public)")
    }

    /// Xcode running, live file, route, and whether coding would project.
    func logCodingCircuit(
        route: AmbientRoute,
        focusedApplicationID: String?,
        actionTurn: Bool,
        editIntent: EditIntent?
    ) {
        let claims = CodeSurfaceSupport.shared.all()
        let standing = CodeSurfaceObserver.shared.observedPlace?.application
        if let hit = SurfacePollTarget.pairHit(
            claims: claims, standingApplicationID: standing)
        {
            let line = "code surface — running pid=\(hit.pid) app=\(hit.place.displayName)"
                + " frontmost=\(hit.isFrontmost)"
            Self.turnLog.info("\(line, privacy: .public)")
        } else {
            Self.turnLog.info(
                "code surface — none running; pair-coding skills would no-op on current_file")
        }

        let focused = focusedApplicationID ?? "none"
        let lead = route.leadApplicationID ?? "none"
        let leadPlace = route.leadPlace?.token ?? "none"
        let leadFocus = route.leadPlace?.focus.map(\.rawValue) ?? "none"
        let leadLine = "lead — focused=\(focused) routeLead=\(lead)"
            + " place=\(leadPlace) focus=\(leadFocus)"
        Self.turnLog.info("\(leadLine, privacy: .public)")

        let observer = CodeSurfaceObserver.shared.ambientLine ?? "none"
        Self.turnLog.info("file — observer \(observer, privacy: .public)")

        let edit = editIntent?.shape.rawValue ?? "none"
        let abilities = route.gate.requestedAbilities
            .map(\.rawValue).sorted().joined(separator: ",")
        let abilityList = abilities.isEmpty ? "none" : abilities
        let family = route.leadPlace?.ability?.rawValue ?? "none"
        let routeLine = "route — intent=\(route.intent.rawValue)"
            + " decidedBy=\(route.decidedBy.rawValue)"
            + " actionTurn=\(actionTurn) edit=\(edit)"
            + " deictic=\(route.verdicts.isDeictic)"
            + " selectionDefinesTurn=\(route.selectionDefinesTurn)"
            + " workspaceFamily=\(family)"
            + " requestedAbilities=\(abilityList)"
        Self.turnLog.info("\(routeLine, privacy: .public)")

        let codingProjected = AmbientApplicationIndexProvider.current
            .registration(place: route.leadPlace)?.place.focus == .coding
            && route.intent != .converse
        if codingProjected {
            Self.turnLog.info(
                "persona — coding ability would project (lead is coding, not converse)")
        } else {
            let line = "persona — coding ability would not project"
                + " (lead focus=\(leadFocus) intent=\(route.intent.rawValue))"
            Self.turnLog.info("\(line, privacy: .public)")
        }

        TurnCircuitLog.roster(trace: dispatcher?.abilityRosterTrace ?? .empty)
    }
}

/// Roster / lane-miss sentences callable off the actor (AbilityRuntime, lanes).
enum TurnCircuitLog {

    static func roster(trace: AbilityRosterTrace) {
        var bits: [String] = []
        var seen: Set<String> = []
        for name in MaryBrain.codingCircuitSkills {
            if let decision = trace.decisions.first(where: {
                $0.reference.invocationName == name
                    || $0.reference.bindingOperation == name
            }) {
                seen.insert(name)
                if decision.disposition == .selected {
                    bits.append("\(name) selected")
                } else {
                    bits.append(
                        "\(name) \(decision.disposition.rawValue) (\(decision.reason))")
                }
            }
        }
        for name in MaryBrain.codingCircuitSkills where !seen.contains(name) {
            bits.append("\(name) not in roster")
        }
        let line = "roster — " + bits.joined(separator: "; ")
        MaryBrain.turnLog.info("\(line, privacy: .public)")
    }

    static func rosterExposed(
        snapshot: AbilityRuntime.Snapshot,
        roster: AbilityRosterArbitration,
        scope: (lead: AmbientPlace, admitted: Set<AmbientPlace>)?,
        exposed: Set<String>
    ) {
        var bits: [String] = []
        for name in MaryBrain.codingCircuitSkills {
            let runtime = snapshot.skill(invocationName: name)
                ?? snapshot.skill(bindingOperation: name)
            guard let runtime else {
                bits.append("\(name) not in snapshot")
                continue
            }
            let offered = exposed.contains(runtime.reference.invocationName)
                || exposed.contains(name)
            if roster.contains(runtime), offered {
                bits.append("\(name) exposed")
            } else if roster.contains(runtime) {
                bits.append("\(name) selected but place-scope hid it")
            } else if let failure = roster.failure(for: runtime) {
                bits.append("\(name) hidden — \(failure)")
            } else {
                bits.append("\(name) not offered")
            }
        }
        let line = "roster — " + bits.joined(separator: "; ")
        MaryBrain.turnLog.info("\(line, privacy: .public)")
        if let scope {
            let admitted = scope.admitted.map(\.token).sorted().joined(separator: ",")
            let scopeLine = "roster — scope lead=\(scope.lead.token) admitted=\(admitted)"
            MaryBrain.turnLog.info("\(scopeLine, privacy: .public)")
        } else {
            MaryBrain.turnLog.info("roster — scope unrestricted")
        }
    }

    static func laneNOOP(offeredNames: [String]) {
        let coding = MaryBrain.codingCircuitSkills.filter { offeredNames.contains($0) }
        if coding.isEmpty {
            MaryBrain.turnLog.info("laneB — NOOP; no coding skills were on the roster")
        } else {
            let line = "laneB — NOOP; offered \(coding.joined(separator: ", ")) unused"
            MaryBrain.turnLog.info("\(line, privacy: .public)")
        }
    }

    static func dispatch(
        name: String, ok: Bool, foundNothing: Bool, disposition: String
    ) {
        guard MaryBrain.codingCircuitSkills.contains(name) else { return }
        let line = "dispatch \(name) — ok=\(ok) foundNothing=\(foundNothing)"
            + " status=\(disposition)"
        MaryBrain.turnLog.info("\(line, privacy: .public)")
    }
}
