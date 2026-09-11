//
//  AbilityRuntime+Arguments.swift
//  MaryBrain
//
//  WHAT: Argument tolerance — a loose model still dispatches.
//  IN:   the model's raw JSON arguments
//  OUT:  strings keyed by the binding's DECLARED parameter names
//  PIN:  A key that is itself a declared parameter is never a loose spelling
//        of another one.
//
import MaryFoundation
import MaryPlugin
import Foundation

extension AbilityRuntime {

    /// The turn's arguments, canonically ordered.
    static func canonicalArguments(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: canonical, encoding: .utf8)
        else { return argumentsJSON }
        return text
    }

    /// The dispatched binding's enum parameters, carrying the package's own
    /// spoken words for their values.
    ///
    /// TWO SCHEMAS DESCRIBE ONE PARAMETER and only one of them can hold
    /// authoring: the adapter's `ModelSkillSchema.Parameter` is what the model
    /// was offered and what the binding will read, while `spokenValues` is
    /// package data on `ModelParameterSchema`. Joined by name here so a native
    /// binding with no package schema still repairs from its own enum values,
    /// which are words a person can say too.
    static func enumParameters(
        binding: SkillBinding,
        declared: AbilityRuntimeSkill?
    ) -> [ModelParameterSchema] {
        let spoken = Dictionary(
            (declared?.skill.modelExposure.parameters ?? [])
                .map { ($0.name, $0.spokenValues) },
            uniquingKeysWith: { first, _ in first })
        return binding.parameters.compactMap { parameter in
            guard let values = parameter.enumValues, !values.isEmpty else { return nil }
            return ModelParameterSchema(
                name: parameter.name,
                type: parameter.type,
                summary: parameter.description,
                required: parameter.required,
                enumValues: values,
                spokenValues: spoken[parameter.name] ?? [:])
        }
    }

    /// Whether an application argument names the Skill's own host Ability —
    /// "window-management", "Window Management" — which is never its target.
    static func namesOwnHost(_ value: String, ability: AbilityID) -> Bool {
        func folded(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let key = folded(value)
        return !key.isEmpty && key == folded(ability.rawValue)
    }

    // MARK: - Argument tolerance (ported verbatim)

    /// Adopt a drifted param name ("project_name" for "project") under the declared name.
    static func reconcile(
        _ arguments: [String: String],
        against parameters: [ModelSkillSchema.Parameter]
    ) -> [String: String] {
        var result = arguments
        // A key that is itself a declared parameter is never a loose spelling of another.
        let declared = Set(parameters.map { $0.name.lowercased() })
        // Declared aliases first, matched exactly — loose containment stole sibling values.
        let byLowercasedKey = Dictionary(
            arguments.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        for parameter in parameters where result[parameter.name] == nil {
            for alias in parameter.aliases {
                let candidate = alias.lowercased()
                // An alias that is itself a declared parameter belongs to that one.
                guard !declared.contains(candidate) else { continue }
                if let value = byLowercasedKey[candidate] {
                    result[parameter.name] = value
                    break
                }
            }
        }
        for parameter in parameters where result[parameter.name] == nil {
            let want = parameter.name.lowercased()
            // Sorted — `Dictionary.first(where:)` has no order; loose ties used to flip.
            if let (_, value) = arguments.sorted(by: { $0.key < $1.key })
                .first(where: { key, _ in
                    let have = key.lowercased()
                    guard !declared.contains(have) else { return false }
                    return have.contains(want) || want.contains(have)
                }) {
                result[parameter.name] = value
            }
        }
        return result
    }

    /// JSON args → strings. Numbers and bools stringify so a loose model still dispatches.
    static func stringArguments(fromJSON json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: result[key] = string
            case let bool as Bool: result[key] = bool ? "true" : "false"
            case let number as NSNumber: result[key] = number.stringValue
            case let array as [Any]:
                if JSONSerialization.isValidJSONObject(array),
                   let data = try? JSONSerialization.data(
                       withJSONObject: array, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            case let dictionary as [String: Any]:
                if JSONSerialization.isValidJSONObject(dictionary),
                   let data = try? JSONSerialization.data(
                       withJSONObject: dictionary, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            default: break
            }
        }
        return result
    }
}
