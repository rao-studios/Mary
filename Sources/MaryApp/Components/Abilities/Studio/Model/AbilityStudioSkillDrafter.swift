//
//  AbilityStudioSkillDrafter.swift
//  Mary
//
//  WHAT: Seer drafts the blocks for a new action from a goal and a live AX read.
//  IN:   Draft-a-skill sheet.
//  OUT:  a proposed PluginOperationSchema, written through mutateAuthoringDocument.
//  PIN:  Two schema truths shape the whole prompt. A recipe RETURNS NOTHING —
//        PluginOperationSchema refuses `output` outright. And an anchor names
//        FIXED text: only typed text carries an input. A drafter that forgets
//        either writes blocks that silently do nothing.
//

import MaryBrain
import Foundation

/// What came back. A refusal is a real answer, not a failure.
enum AbilityStudioDraftOutcome {
    case drafted(AbilityStudioDraftedAction)
    /// The goal needs a faculty compiled into Mary. The Studio cannot write one.
    case needsFaculty(reason: String)
}

struct AbilityStudioDraftedAction {
    let title: String
    let summary: String
    let inputs: [PluginOperationInputSchema]
    let steps: [PluginRecipeStepSchema]
    let cleanupSteps: [PluginRecipeStepSchema]
    /// Step ids the model guessed at rather than read from the capture — a menu
    /// it could not see. The author runs these once before keeping them.
    let unverifiedStepIDs: Set<String>

    func isUnverified(_ step: PluginRecipeStepSchema) -> Bool {
        unverifiedStepIDs.contains(step.id)
    }
}

enum AbilityStudioDraftError: LocalizedError {
    case notSignedIn
    case emptyGoal
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Seer is not signed in, so nothing can be drafted right now."
        case .emptyGoal:
            return "Say what the ability should be able to do."
        case .unreadable(let detail):
            return "Seer's answer could not be read as blocks — \(detail)"
        }
    }
}

struct AbilityStudioSkillDrafter {

    private let complete: any SeerCompleteProviding

    init(complete: any SeerCompleteProviding) {
        self.complete = complete
    }

    func isReady() async -> Bool {
        await complete.isReady()
    }

    func draft(
        goal: String,
        application: String,
        frames: [AbilityStudioSurfaceFrame]
    ) async throws -> AbilityStudioDraftOutcome {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AbilityStudioDraftError.emptyGoal }
        guard await complete.isReady() else { throw AbilityStudioDraftError.notSignedIn }

        let answer = try await complete.complete(
            instructions: Self.instructions,
            messages: [.init(role: "user", content: Self.request(
                goal: trimmed,
                application: application,
                frames: frames))])
        return try Self.decode(answer, frames: frames)
    }

    // MARK: - Prompt

    /// The closed vocabularies are spelled out because the model may only emit
    /// what the schema already defines; anything else is refused on decode.
    static var instructions: String {
        let stepKinds = PluginRecipeStepKind.authorableCases
            .map(\.rawValue)
            .joined(separator: ", ")
        let roles = PluginAccessibilityRole.allCases
            .map(\.rawValue)
            .joined(separator: ", ")
        return """
        You author one bounded macOS UI action for Mary, as JSON and nothing else.

        Two rules decide whether an action is possible at all:
        1. An action RETURNS NOTHING. It clicks, types, scrolls and waits. It \
        cannot read a value back, report state, or answer a question. If the \
        goal needs a value returned, refuse.
        2. An accessibility anchor names FIXED text. Only a typeText step can \
        carry a parameter. If the goal needs a parameter to select something, \
        route it through a text field the user can type into — otherwise refuse.

        Refuse by answering exactly: {"needsFaculty": "<one sentence saying \
        what Mary would need>"}

        Otherwise answer:
        {"title": "...", "summary": "...",
         "inputs": [{"name": "...", "kind": "text|number|integer|boolean", \
        "required": true}],
         "steps": [ ... ], "cleanupSteps": [ ... ]}

        A step is {"id": "lower-case-hyphenated", "kind": "<one of: \(stepKinds)>"} plus:
          keyChord: "key" (a single letter/digit/named key), \
        "modifiers": ["command"|"option"|"control"|"shift"|"function"]
          typeText: "text": {"value": "..."} or {"input": "<an input name>"}
          wait: "durationSeconds": 0.1-5
          captureAccessibilityAnchor: "accessibilityLocator": {"role": \
        "<one of: \(roles)>", "identifier": "<exact label>", \
        "descendantRole": "...", "descendantTitle": "..."}
          pointerClick / pointerMove: no fields; they act on the last captured anchor
          scroll: "deltaX"/"deltaY": {"value": <number>}

        Only name an anchor whose label appears in the frames you were given. \
        If a step depends on something you were not shown — a menu that opens \
        on click — still write it, and list its id in "unverified".

        Keep it to at most eight steps. Answer with one JSON object, no prose.
        """
    }

    static func request(
        goal: String,
        application: String,
        frames: [AbilityStudioSurfaceFrame]
    ) -> String {
        let visible = frames.isEmpty
            ? "(none selected — do not name any anchor)"
            : frames.map { "- \($0.line)" }.joined(separator: "\n")
        return """
        Application: \(application)

        Goal: \(goal)

        Accessibility frames the author selected:
        \(visible)
        """
    }

    // MARK: - Decode

    /// Wire shape. Decoding into these and then into the real schema types is
    /// what keeps a hallucinated field out of the package.
    private struct Wire: Decodable {
        var needsFaculty: String?
        var title: String?
        var summary: String?
        var inputs: [WireInput]?
        var steps: [WireStep]?
        var cleanupSteps: [WireStep]?
        var unverified: [String]?
    }

    private struct WireInput: Decodable {
        var name: String
        var kind: String?
        var required: Bool?
    }

    private struct WireText: Decodable {
        var value: String?
        var input: String?
    }

    private struct WireScalar: Decodable {
        var value: Double?
        var input: String?
    }

    private struct WireLocator: Decodable {
        var role: String?
        var identifier: String?
        var descendantRole: String?
        var descendantIdentifier: String?
        var descendantTitle: String?
        var descendantLabelText: String?
    }

    private struct WireStep: Decodable {
        var id: String
        var kind: String
        var key: String?
        var modifiers: [String]?
        var text: WireText?
        var durationSeconds: Double?
        var accessibilityLocator: WireLocator?
        var deltaX: WireScalar?
        var deltaY: WireScalar?
    }

    static func decode(
        _ answer: String,
        frames: [AbilityStudioSurfaceFrame]
    ) throws -> AbilityStudioDraftOutcome {
        guard let json = jsonObject(in: answer) else {
            throw AbilityStudioDraftError.unreadable("no JSON object in the reply")
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        } catch {
            throw AbilityStudioDraftError.unreadable(error.localizedDescription)
        }

        if let refusal = wire.needsFaculty?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refusal.isEmpty {
            return .needsFaculty(reason: refusal)
        }

        let title = (wire.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw AbilityStudioDraftError.unreadable("no title")
        }
        let steps = (wire.steps ?? []).compactMap(step(from:))
        guard !steps.isEmpty else {
            throw AbilityStudioDraftError.unreadable("no usable blocks")
        }

        // Anchors naming a label the author never showed it are the model's
        // guesses, whether or not it admitted to guessing.
        let shown = Set(frames.map { $0.label.lowercased() })
        var unverified = Set(wire.unverified ?? [])
        for wireStep in wire.steps ?? [] {
            guard let identifier = wireStep.accessibilityLocator?.identifier?.lowercased(),
                  !shown.contains(identifier)
            else { continue }
            unverified.insert(wireStep.id)
        }

        return .drafted(AbilityStudioDraftedAction(
            title: title,
            summary: (wire.summary ?? title)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            inputs: (wire.inputs ?? []).map(input(from:)),
            steps: steps,
            cleanupSteps: (wire.cleanupSteps ?? []).compactMap(step(from:)),
            unverifiedStepIDs: unverified))
    }

    /// Models like to wrap JSON in prose or a fence. Take the outermost object.
    static func jsonObject(in answer: String) -> String? {
        guard let start = answer.firstIndex(of: "{"),
              let end = answer.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(answer[start...end])
    }

    private static func input(from wire: WireInput) -> PluginOperationInputSchema {
        PluginOperationInputSchema(
            name: wire.name,
            kind: PluginOperationInputKind(rawValue: wire.kind ?? "text") ?? .text,
            required: wire.required ?? true)
    }

    /// Anything outside the closed vocabularies is dropped rather than coerced.
    private static func step(from wire: WireStep) -> PluginRecipeStepSchema? {
        guard let kind = PluginRecipeStepKind(rawValue: wire.kind),
              PluginRecipeStepKind.authorableCases.contains(kind),
              SchemaIdentifierValidation.isValid(wire.id)
        else { return nil }

        var step = PluginRecipeStepSchema(id: wire.id, kind: kind)
        switch kind {
        case .keyChord:
            guard let key = wire.key.flatMap(PluginKey.init(rawValue:)) else { return nil }
            step.key = key
            step.modifiers = (wire.modifiers ?? []).compactMap(PluginKeyModifier.init(rawValue:))
        case .typeText:
            guard let text = wire.text else { return nil }
            if let input = text.input {
                step.text = .init(input: input)
            } else if let value = text.value {
                step.text = .init(value: value)
            } else {
                return nil
            }
        case .wait:
            step.durationSeconds = min(max(wire.durationSeconds ?? 0.3, 0.05), 5)
        case .captureAccessibilityAnchor:
            guard let locator = wire.accessibilityLocator,
                  let role = locator.role.flatMap(PluginAccessibilityRole.init(rawValue:)),
                  let identifier = locator.identifier
            else { return nil }
            step.accessibilityLocator = .init(
                role: role,
                identifier: identifier,
                descendantRole: locator.descendantRole
                    .flatMap(PluginAccessibilityRole.init(rawValue:)),
                descendantIdentifier: locator.descendantIdentifier,
                descendantTitle: locator.descendantTitle,
                descendantLabelText: locator.descendantLabelText)
        case .scroll:
            step.deltaX = wire.deltaX?.value.map { .init(value: $0) }
            step.deltaY = wire.deltaY?.value.map { .init(value: $0) }
        case .pointerMove, .pointerClick, .pointerDrag, .pointerSquareDrag,
             .rebindFocusedWindow:
            break
        }
        return step
    }
}
