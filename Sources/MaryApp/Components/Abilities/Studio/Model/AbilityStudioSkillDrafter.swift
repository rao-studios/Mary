//
//  AbilityStudioSkillDrafter.swift
//  Mary
//
//  WHAT: Sewn drafts the blocks for a new action from a goal and a live AX read.
//  IN:   Draft-a-skill sheet.
//  OUT:  a proposed PluginOperationSchema, written through mutateAuthoringDocument.
//  PIN:  Two schema truths shape the whole prompt. A recipe RETURNS NOTHING —
//        PluginOperationSchema refuses `output` outright. And an anchor names
//        FIXED text: only typed text carries an input. A drafter that forgets
//        either writes blocks that silently do nothing.
//  PIN:  TOLERANT ON THE WAY IN, STRICT ON THE WAY OUT — the same contract every
//        other model-JSON reader in Mary keeps. A tiny utility model drifts on
//        shape; it must never drift past a closed vocabulary.
//

import MaryBrain
import Foundation
import os

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
            return "Sewn is not signed in, so nothing can be drafted right now."
        case .emptyGoal:
            return "Say what the ability should be able to do."
        case .unreadable(let detail):
            return "Sewn's answer could not be read as blocks — \(detail)"
        }
    }
}

struct AbilityStudioSkillDrafter {

    /// MaryApp's first logger, and it earns its place: nothing on this path was
    /// recorded anywhere, so a failed draft left no trace but a red line in a
    /// sheet the author had already dismissed.
    private static let log = Logger(subsystem: "nyc.rao.mary", category: "abilities")

    private let complete: any SewnCompleteProviding

    init(complete: any SewnCompleteProviding) {
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
                frames: frames))],
            // A RECIPE IS NOT AN ANNOTATION. This route's default budget is
            // sized for one precis and a few labels; eight blocks plus their
            // anchors do not fit in it, and what comes back is not a short
            // answer but an unparsable one.
            maxTokens: SewnCompleteBudget.recipe)
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

    static func decode(
        _ answer: String,
        frames: [AbilityStudioSurfaceFrame]
    ) throws -> AbilityStudioDraftOutcome {
        let json: String
        switch extractObject(in: answer) {
        case .object(let found):
            json = found
        case .absent:
            throw unreadable("no JSON object in the reply", answer: answer)
        case .truncated:
            throw unreadable("the answer was cut off before it finished", answer: answer)
        }

        guard let object = try? JSONSerialization.jsonObject(
                with: Data(json.utf8)) as? [String: Any] else {
            throw unreadable("the reply was not a JSON object", answer: answer)
        }

        if let refusal = string(object["needsFaculty"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !refusal.isEmpty {
            return .needsFaculty(reason: refusal)
        }

        let title = (string(object["title"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw unreadable("no title", answer: answer)
        }
        let rawSteps = objects(object["steps"])
        let steps = rawSteps.compactMap(step(from:))
        guard !steps.isEmpty else {
            throw unreadable("no usable blocks", answer: answer)
        }

        // Anchors naming a label the author never showed it are the model's
        // guesses, whether or not it admitted to guessing.
        let shown = Set(frames.map { $0.label.lowercased() })
        var unverified = Set(strings(object["unverified"]))
        for rawStep in rawSteps {
            guard let id = string(rawStep["id"]),
                  let locator = rawStep["accessibilityLocator"] as? [String: Any],
                  let identifier = string(locator["identifier"])?.lowercased(),
                  !shown.contains(identifier)
            else { continue }
            unverified.insert(id)
        }

        return .drafted(AbilityStudioDraftedAction(
            title: title,
            summary: (string(object["summary"]) ?? title)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            inputs: objects(object["inputs"]).compactMap(input(from:)),
            steps: steps,
            cleanupSteps: objects(object["cleanupSteps"]).compactMap(step(from:)),
            unverifiedStepIDs: unverified))
    }

    /// Every unreadable answer is logged before it is thrown, length first.
    /// The count is the diagnosis more often than the excerpt is: a reply that
    /// stops at the token ceiling looks like nonsense and is merely short.
    private static func unreadable(
        _ detail: String, answer: String
    ) -> AbilityStudioDraftError {
        log.error(
            """
            skill draft unreadable — \(detail, privacy: .public): \
            \(answer.count, privacy: .public) chars, begins \
            \(answer.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)
            """)
        return AbilityStudioDraftError.unreadable(detail)
    }

    // MARK: - Extraction

    /// What the scan for the outermost `{…}` found.
    enum Extraction: Equatable {
        case object(String)
        /// No `{` anywhere — prose, an apology, a refusal in words.
        case absent
        /// A `{` that never balanced: the answer stopped mid-object.
        case truncated
    }

    /// Models wrap JSON in prose or a fence, so take the outermost object by
    /// counting depth — and count OUTSIDE string literals, because every anchor
    /// in a drafted recipe carries a literal UI label and a label may contain a
    /// brace.
    ///
    /// TRUNCATION IS ITS OWN ANSWER. Taking `firstIndex(of: "{")` through
    /// `lastIndex(of: "}")` cannot tell a finished object from one cut off
    /// mid-step: it hands the parser an inner brace and lets it fail with a
    /// message that names nothing. Depth counting knows the difference, and
    /// saying which one happened is the whole distance between a mystery and a
    /// diagnosis.
    static func extractObject(in answer: String) -> Extraction {
        guard let start = answer.firstIndex(of: "{") else { return .absent }
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = start
        while index < answer.endIndex {
            let character = answer[index]
            if isEscaped {
                isEscaped = false
            } else if isInString {
                if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                switch character {
                case "\"":
                    isInString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return .object(String(answer[start...index])) }
                default:
                    break
                }
            }
            index = answer.index(after: index)
        }
        return .truncated
    }

    // MARK: - Shape drift
    //
    // A tiny utility model writes `"required": "true"` and a bare `-300` for a
    // scroll delta as readily as the shapes the prompt asked for. Every sibling
    // reader in Mary shrugs that off — `UnitAnnotationPrompt.parse`,
    // `AbilityRuntime.stringArguments`, `SkillCallTextInterceptor` — and this
    // one used to throw a whole usable draft away over a single quoted bool.
    //
    // Drift in SHAPE is forgiven. Drift out of a closed VOCABULARY never is:
    // an unknown step kind, key or role is dropped, not coerced.

    /// A string, however the model spelled it.
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// A number written as a number, or quoted as a string.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A boolean written as one, quoted as a word, or sent as 0/1.
    static func boolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// `{"value": 12}` as the prompt asks, or the bare `12` models send.
    static func scalar(_ value: Any?) -> Double? {
        if let object = value as? [String: Any] { return number(object["value"]) }
        return number(value)
    }

    /// `{"value": …}` / `{"input": …}` as asked, or a bare string. An input
    /// wins over a literal: a step bound to a parameter is the stronger claim.
    static func textExpression(_ value: Any?) -> PluginTextExpression? {
        if let object = value as? [String: Any] {
            if let input = string(object["input"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !input.isEmpty {
                return .init(input: input)
            }
            if let literal = string(object["value"]) { return .init(value: literal) }
            return nil
        }
        if let literal = string(value) { return .init(value: literal) }
        return nil
    }

    /// The dictionaries in an array field, ignoring whatever else is in it.
    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// The strings in an array field, however each one was written.
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { string($0) } ?? []
    }

    // MARK: - Mapping

    private static func input(from raw: [String: Any]) -> PluginOperationInputSchema? {
        guard let name = string(raw["name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return PluginOperationInputSchema(
            name: name,
            kind: string(raw["kind"])
                .flatMap(PluginOperationInputKind.init(rawValue:)) ?? .text,
            required: boolean(raw["required"]) ?? true)
    }

    /// Anything outside the closed vocabularies is dropped rather than coerced.
    private static func step(from raw: [String: Any]) -> PluginRecipeStepSchema? {
        guard let id = string(raw["id"]),
              SchemaIdentifierValidation.isValid(id),
              let kind = string(raw["kind"]).flatMap(PluginRecipeStepKind.init(rawValue:)),
              PluginRecipeStepKind.authorableCases.contains(kind)
        else { return nil }

        var step = PluginRecipeStepSchema(id: id, kind: kind)
        switch kind {
        case .keyChord:
            guard let key = string(raw["key"]).flatMap(PluginKey.init(rawValue:))
            else { return nil }
            step.key = key
            step.modifiers = strings(raw["modifiers"])
                .compactMap(PluginKeyModifier.init(rawValue:))
        case .typeText:
            guard let text = textExpression(raw["text"]) else { return nil }
            step.text = text
        case .wait:
            step.durationSeconds = min(max(number(raw["durationSeconds"]) ?? 0.3, 0.05), 5)
        case .captureAccessibilityAnchor:
            guard let locator = raw["accessibilityLocator"] as? [String: Any],
                  let role = string(locator["role"])
                    .flatMap(PluginAccessibilityRole.init(rawValue:)),
                  let identifier = string(locator["identifier"])
            else { return nil }
            step.accessibilityLocator = .init(
                role: role,
                identifier: identifier,
                descendantRole: string(locator["descendantRole"])
                    .flatMap(PluginAccessibilityRole.init(rawValue:)),
                descendantIdentifier: string(locator["descendantIdentifier"]),
                descendantTitle: string(locator["descendantTitle"]),
                descendantLabelText: string(locator["descendantLabelText"]))
        case .scroll:
            step.deltaX = scalar(raw["deltaX"]).map { .init(value: $0) }
            step.deltaY = scalar(raw["deltaY"]).map { .init(value: $0) }
        case .pointerMove, .pointerClick, .pointerDrag, .pointerSquareDrag,
             .rebindFocusedWindow:
            break
        }
        return step
    }
}
