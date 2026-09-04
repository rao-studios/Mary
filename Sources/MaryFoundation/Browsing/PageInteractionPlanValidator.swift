//
//  PageInteractionPlanValidator.swift
//  MaryFoundation
//
//  WHAT: Strict admission for a model-authored page plan.
//  IN:   one JSON array of command objects  OUT: PageInteractionPlanValidationResult
//  PIN:  PARSING IS MANUAL ON PURPOSE. Codable would make unknown-field rejection and
//        diagnostic positions depend on decoder internals; here every accepted value is
//        finite, bounded and fully typed before anything touches a machine.
//        THE WHOLE PLAN IS ADMITTED BEFORE THE FIRST COMMAND RUNS. A plan that would
//        exceed the budget halfway through must refuse while nothing has happened —
//        stopping midway leaves the page in a state nobody asked for and nobody named.
//

import CoreFoundation
import Foundation

public enum PageInteractionPlanValidator {
    public static let maximumCommands = 16
    public static let maximumPlanBytes = 32 * 1_024
    public static let maximumTargetBytes = 512
    public static let maximumTypeTextBytes = 4_096
    public static let maximumScrollDelta = 2_000.0
    public static let maximumDurationSeconds = 2.0
    public static let minimumDragDurationSeconds = 0.01
    public static let defaultDragDurationSeconds = 0.18
    /// The executor's own hover-then-drag for a range. Beside admission so the worst
    /// case cannot drift from what actually runs.
    public static let rangeDragDurationSeconds = 0.22
    /// The ceiling on synthetic input one plan may emit. A plan is refused before any
    /// window comes forward, so reaching the ceiling can never strand a half-pressed key.
    public static let maximumInputEvents = 4_096

    static let structuralFields: Set<String> = ["kind"]

    public static func validate(planJSON: String) -> PageInteractionPlanValidationResult {
        guard planJSON.utf8.count <= maximumPlanBytes else {
            return .invalid([.init(
                code: .planTooLarge,
                message: "The page plan is larger than \(maximumPlanBytes) bytes.")])
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(
                with: Data(planJSON.utf8), options: [.fragmentsAllowed])
        } catch {
            return .invalid([.init(
                code: .invalidJSON, message: "The page plan is not valid JSON.")])
        }
        guard let elements = parsed as? [Any] else {
            return .invalid([.init(
                code: .planMustBeArray,
                message: "A page plan is one JSON array of command objects.")])
        }
        guard !elements.isEmpty else {
            return .invalid([.init(code: .emptyPlan, message: "The page plan has no commands.")])
        }
        guard elements.count <= maximumCommands else {
            return .invalid([.init(
                code: .tooManyCommands,
                message: "A page plan may hold at most \(maximumCommands) commands.")])
        }

        var issues: [PageInteractionPlanIssue] = []
        var commands: [PageInteractionPlanCommand] = []
        for (sourceIndex, element) in elements.enumerated() {
            guard let object = element as? [String: Any] else {
                append(
                    .commandMustBeObject, sourceIndex: sourceIndex,
                    message: "Each command must be a JSON object.", to: &issues)
                continue
            }
            guard let rawKind = object["kind"] else {
                append(
                    .missingKind, sourceIndex: sourceIndex, field: "kind",
                    message: "Every command needs a kind.", to: &issues)
                continue
            }
            guard let kindText = rawKind as? String else {
                append(
                    .invalidType, sourceIndex: sourceIndex, field: "kind",
                    message: "kind must be a string.", to: &issues)
                continue
            }
            guard let kind = PageInteractionCommandKind(rawValue: kindText) else {
                append(
                    .unknownKind, sourceIndex: sourceIndex, field: "kind",
                    message: "There is no command kind called \(kindText).", to: &issues)
                continue
            }

            let issueCount = issues.count
            rejectUnknownFields(
                in: object, allowed: allowedFields(for: kind),
                sourceIndex: sourceIndex, issues: &issues)
            let action = parse(kind, object: object, sourceIndex: sourceIndex, issues: &issues)
            if issues.count == issueCount, let action {
                commands.append(.init(sourceIndex: sourceIndex, action: action))
            }
        }

        guard issues.isEmpty else { return .invalid(sorted(issues)) }
        let plan = PageInteractionPlan(commands: commands)
        if let index = terminalHover(in: plan) {
            return .invalid([.init(
                sourceIndex: index, code: .terminalHover, field: "kind",
                message: "hover has to lead somewhere — the pointer is put back when the plan ends.")])
        }
        let events = estimatedInputEvents(for: plan)
        guard events <= maximumInputEvents else {
            return .invalid([.init(
                code: .eventBudgetExceeded,
                message: "That plan would send \(events) input events; the limit is \(maximumInputEvents).")])
        }
        return .valid(plan)
    }

    /// Deterministic order, independent of dictionary iteration.
    public static func sorted(
        _ issues: [PageInteractionPlanIssue]
    ) -> [PageInteractionPlanIssue] {
        issues.sorted { lhs, rhs in
            let leftIndex = lhs.sourceIndex ?? -1
            let rightIndex = rhs.sourceIndex ?? -1
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            if lhs.code.rawValue != rhs.code.rawValue {
                return lhs.code.rawValue < rhs.code.rawValue
            }
            if (lhs.field ?? "") != (rhs.field ?? "") {
                return (lhs.field ?? "") < (rhs.field ?? "")
            }
            return lhs.message < rhs.message
        }
    }

    // MARK: - Budget

    /// Worst-case input packets, counted before any window is touched.
    public static func estimatedInputEvents(for plan: PageInteractionPlan) -> Int {
        plan.commands.reduce(into: 0) { count, command in
            switch command.action {
            case .click(let click):
                // Down and up per click, plus the travel to get there.
                count += pointerTravelEvents + click.count * 2
            case .hover:
                count += pointerTravelEvents
            case .drag(let drag):
                count += pointerTravelEvents + 2 + dragSteps(duration: drag.durationSeconds)
            case .keyChord:
                count += 2
            case .typeText(let typing):
                count += typing.text.utf8.count * 2
                if typing.target != nil { count += pointerTravelEvents + 2 }
                if typing.submit { count += 2 }
            case .adjust:
                // Travel, then the same drag the executor falls back to.
                count += pointerTravelEvents * 2 + 2
                    + dragSteps(duration: rangeDragDurationSeconds)
            case .scroll:
                count += 1
            case .wait:
                break
            }
        }
    }

    /// The eased travel a pointer move emits. Matches the hands' own step count.
    static let pointerTravelEvents = 24

    static func dragSteps(duration: Double) -> Int {
        max(2, Int((duration * 60).rounded()))
    }
}
