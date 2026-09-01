//
//  RouteReport.swift
//  Mary
//
//  WHAT: Routes pane Copy serializer — deterministic key: value lines, newest first.
//  OUT:  pasteable routing bug report. Golden-tested.
//

import MaryBrain
import Foundation
import MaryRuntime

enum RouteReport {

    /// The whole pane, newest turn first.
    static func serialize(rows: [RouteRow], at now: Date) -> String {
        var blocks = [header(rows: rows, at: now)]
        blocks.append(contentsOf: rows.map { rowBlock($0, at: now) })
        return blocks.joined(separator: "\n\n")
    }

    /// `1.2s` under a minute, `3m 12s` under an hour, `1h 3m` beyond. Shared
    /// vocabulary with PerceptionReport on purpose: two panes pasted into one
    /// report must not spell an age two ways.
    static func ageString(_ seconds: TimeInterval) -> String {
        PerceptionReport.ageString(seconds)
    }

    // MARK: - Blocks

    private static func header(rows: [RouteRow], at now: Date) -> String {
        var lines = ["=== Mary ABILITY ROUTES \(timestamp(now)) ==="]
        lines.append("turns: \(rows.count)")
        lines.append("ability.runs: \(rows.flatMap(\.skillRuns).count)")
        lines.append("ability.blocked: \(rows.flatMap(\.skillRuns).filter { $0.status == .blocked }.count)")
        lines.append("registry.revisions: \(Set(rows.map(\.registryRevision)).count)")
        // Distribution, so a taxonomy that never fires a case is visible.
        for intent in AmbientIntent.allCases {
            let count = rows.filter { $0.intent == intent }.count
            guard count > 0 else { continue }
            lines.append("intent.\(intent.rawValue): \(count)")
        }
        return lines.joined(separator: "\n")
    }

    private static func rowBlock(_ row: RouteRow, at now: Date) -> String {
        var lines = ["--- \(row.intent.rawValue) via \(row.decidedBy.rawValue) ---"]
        lines.append("age: \(ageString(row.age(at: now)))")
        lines.append("utterance: \(oneLine(row.utterance))")
        // Place token when resolved; native token == rawValue.
        lines.append("lead: \(row.leadPlace?.token ?? row.lead?.rawValue ?? "none")")
        lines.append("lead.class: \(row.leadPlace?.placeClass.rawValue ?? "none")")
        lines.append("named: \(list(row.namedPlaces.map(\.token)))")
        lines.append("world.candidates: \(list(row.candidateAttentions.map(\.rawValue)))")
        lines.append("ranking: \(row.rankingMode.rawValue)")
        if let attention = row.world {
            let subject = attention.subject.map { "#\($0)" } ?? ""
            lines.append("attention: \(attention.sense.rawValue)@\(attention.attention.rawValue)\(subject)")
        }
        lines.append("writing.target: \(row.writingTarget?.rawValue ?? "none")")
        lines.append("writing.context: \(row.supportingContext.map(oneLine) ?? "none")")
        lines.append("questions: \(list(row.gate.questions.map(\.rawValue).sorted()))")
        lines.append("abilities: \(list(row.gate.requestedAbilities.map(\.rawValue).sorted()))")
        lines.append("applications: \(list(row.gate.applications))")
        lines.append("totems: \(list(row.gate.memory.lanes.map(\.rawValue).sorted()))")
        lines.append("needs.locate: \(yesNo(row.needsLocate))")
        lines.append("needs.pre-read: \(yesNo(row.needsPreRead))")
        lines.append("needs.execution: \(yesNo(row.needsExecution))")
        lines.append("prompt.chars: \(row.systemPromptChars)")
        lines.append("registry.revision: \(row.registryRevision.uuidString)")
        lines.append("registry.packages: \(list(row.packageIDs.map(\.rawValue)))")
        lines.append("skills.exposed: \(row.exposedSkillCount)")
        lines.append("roster.selected: \(list(row.abilityRoster.selected.map { $0.reference.displayLabel }))")
        lines.append("roster.decisions: \(row.abilityRoster.decisions.count)")
        for decision in row.abilityRoster.decisions {
            let key = "candidate.\(decision.reference.packageID.rawValue).\(decision.reference.abilityID.rawValue).\(decision.reference.invocationName)"
            lines.append("\(key): \(decision.disposition.rawValue)")
            lines.append("\(key).group: \(decision.conflictGroup ?? "none")")
            lines.append("\(key).policy: \(decision.policy.rawValue)")
            lines.append("\(key).evidence: total=\(decision.evidence.total), direct=\(decision.evidence.directInteraction), focus=\(decision.evidence.focusedWorkspace)")
            lines.append("\(key).declared-preference: \(decision.evidence.preference)")
            lines.append("\(key).reason: \(oneLine(decision.reason))")
            if let alternative = decision.selectedAlternative {
                lines.append("\(key).selected-alternative: \(alternative.displayLabel)")
            }
            if let primary = decision.fallbackFor {
                lines.append("\(key).fallback-for: \(primary.displayLabel)")
            }
        }
        lines.append("skills.invoked: \(list(row.skillRuns.map { $0.reference.displayLabel }))")
        for run in row.skillRuns {
            let key = "skill.\(run.reference.abilityID.rawValue).\(run.reference.invocationName)"
            lines.append("\(key): \(run.status.rawValue) | \(run.effect.rawValue)")
            if let adapterID = run.reference.adapterID,
               let operation = run.reference.bindingOperation {
                lines.append("\(key).binding: \(adapterID.rawValue)/\(operation)")
            }
            lines.append("\(key).inputs: \(list(run.inputTypes.map(\.rawValue)))")
            lines.append("\(key).outputs: \(list(run.outputTypes.map(\.rawValue)))")
            lines.append("\(key).target-scope: \(run.targetScope?.resolution.rawValue ?? "none")")
            if !run.consumedInteractions.isEmpty {
                let sources = run.consumedInteractions.map {
                    let expiry = $0.expiresAt.map(timestamp) ?? "none"
                    return "\($0.schemaID.rawValue)@\($0.scope.resolution.rawValue)/\($0.completeness.rawValue); captured=\(timestamp($0.capturedAt)); expires=\(expiry)"
                }
                lines.append("\(key).interactions: \(list(sources))")
            }
            if run.foundNothing {
                lines.append("\(key).outcome: no-match")
            }
        }
        let verdicts = row.verdicts
        lines.append("verdict.effectful-turn: \(yesNo(verdicts.actionTurn))")
        lines.append("verdict.edit: \(verdicts.editShape?.rawValue ?? "none")")
        lines.append("verdict.edit-targets: \(list(verdicts.editTargets))")
        lines.append("verdict.named-part: \(verdicts.namedPart.map(oneLine) ?? "none")")
        lines.append("verdict.ambient-source: \(yesNo(verdicts.namesAmbientSource))")
        lines.append("verdict.deictic: \(yesNo(verdicts.isDeictic))")
        lines.append("verdict.transform: \(yesNo(verdicts.namesTransform))")
        lines.append("verdict.override: \(token(verdicts.focusOverride))")
        lines.append("verdict.bare-decision: \(verdicts.bareDecision.map(yesNo) ?? "none")")
        return lines.joined(separator: "\n")
    }

    // MARK: - Atoms

    private static func token(_ focus: WorkspaceFocus?) -> String {
        switch focus {
        case .coding: return "coding"
        case .writing: return "writing"
        case nil: return "none"
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    /// ISO-8601 UTC, second precision — `2026-07-27T14:03:22Z`.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Field rows must stay rows — greppability beats fidelity here.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
