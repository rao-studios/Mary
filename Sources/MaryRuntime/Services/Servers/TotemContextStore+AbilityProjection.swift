//
//  TotemContextStore+AbilityProjection.swift
//

import MaryBrain
import MaryTotem
import Foundation

extension TotemContextStore {

    // MARK: - Ability projection execution

    package struct ProjectedField: Equatable {
        package var name: String
        package var value: String
    }

    package static func durableProjections(
        in plan: AbilityTotemProjectionPlan,
        succeeded: Bool
    ) -> [ResolvedTotemProjection] {
        plan.durableReceipts + (succeeded ? plan.durableContent : [])
    }

    func depositProjectedResult(
        reference: AbilitySkillReference,
        skillName: String,
        argumentsJSON: String,
        summary: String,
        userText: String,
        subject: DepositSubject,
        applicationID: String?,
        policy: ArchivePolicy,
        succeeded: Bool,
        projection: ResolvedTotemProjection,
        ownerID: String
    ) async {
        let fields = Self.projectedFields(
            reference: reference,
            skillName: skillName,
            argumentsJSON: argumentsJSON,
            summary: Self.clamp(summary, limit: summaryLimit),
            userText: userText,
            subject: subject,
            applicationID: applicationID,
            succeeded: succeeded,
            projection: projection)
        // A content schema with no present whitelisted value has no memory to
        // contribute. Skipping it is safer than inventing unprojected prose.
        guard projection.purpose == .receipt || !fields.isEmpty else { return }

        let projectedSubject = Self.projectedSubject(
            subject, fields: projection.includedFields,
            excluded: projection.excludedFields)
        let composition = Self.projectedComposition(
            reference: reference,
            fields: fields,
            subject: projectedSubject,
            applicationID: applicationID,
            projection: projection)

        for destination in Self.projectionDestinations(
            projection: projection,
            subject: projectedSubject,
            routingSubject: subject,
            applicationID: applicationID,
            ownerID: ownerID
        ) {
            let item = DepositItem(
                documentID: Self.documentID(
                    subject: projectedSubject,
                    policy: policy,
                    ownerID: ownerID,
                    lane: destination.lane,
                    projectionID: projection.id),
                texts: [Self.projectionDocument(fields)],
                tags: [
                    "mary",
                    "ability:\(reference.abilityID.rawValue)",
                    "skill:\(reference.skillID.rawValue)",
                    "package:\(reference.packageID.rawValue)",
                    "projection:\(projection.id.rawValue)",
                    "projection-purpose:\(projection.purpose.rawValue)",
                    "totem:\(destination.lane.rawValue)",
                ],
                name: "\(reference.displayLabel) · \(projection.id.rawValue)",
                metadata: Self.metadata(
                    subject: projectedSubject,
                    policy: policy,
                    reference: reference,
                    bindingName: skillName,
                    succeeded: succeeded,
                    projection: projection,
                    lane: destination.lane),
                entities: composition.entities,
                relationships: composition.relationships)
            do {
                try await client.deposit(
                    [item], ownerID: ownerID,
                    groupID: destination.id,
                    groupLabel: destination.label)
            } catch {
                // Fire-and-forget: a missing Totem is a Servers-sheet concern.
                continue
            }
        }
    }

    /// Applies the schema as a strict top-level whitelist. Exclusions win and
    /// are also removed recursively from any selected object or array.
    package static func projectedFields(
        reference: AbilitySkillReference,
        skillName: String,
        argumentsJSON: String,
        summary: String,
        userText: String,
        subject: DepositSubject,
        applicationID: String?,
        succeeded: Bool,
        projection: ResolvedTotemProjection
    ) -> [ProjectedField] {
        let arguments = argumentObject(argumentsJSON)
        let excluded = Set(projection.excludedFields.map { $0.lowercased() })
        let project = subject.projectIdentity.map { ($0 as NSString).lastPathComponent }
        let generated: [String: String?] = [
            "packageID": reference.packageID.rawValue,
            "packageVersion": reference.packageVersion.rawValue,
            "abilityID": reference.abilityID.rawValue,
            "skillID": reference.skillID.rawValue,
            "invocationName": reference.invocationName,
            "adapterID": reference.adapterID?.rawValue,
            "bindingName": skillName,
            "status": succeeded ? "succeeded" : "failed",
            "targetScope": subject.isFocused ? subject.groupLabel : nil,
            "applicationID": applicationID ?? subject.app,
            "projectID": project,
            "project": project,
            "documentID": subject.documentIdentity,
            "summary": summary,
            "userText": userText,
        ]
        let generatedIdentityFields: Set<String> = [
            "packageID", "packageVersion", "abilityID", "skillID",
            "invocationName", "adapterID", "bindingName", "status",
            "targetScope", "applicationID", "projectID", "project",
            "documentID", "windowID", "sessionID", "inputTypes", "outputTypes",
        ]

        return projection.includedFields.sorted().compactMap { name in
            guard !excluded.contains(name.lowercased()) else { return nil }

            // Generated execution facts cannot be shadowed by a provider's
            // argument object. Project is the one dual-source field: an
            // explicit selected project is preferable to the focused fallback.
            if name == "project", !projection.redactContent,
               let value = arguments[name],
               let sanitized = sanitize(value, excluding: excluded),
               let rendered = renderJSONValue(sanitized) {
                return ProjectedField(name: name, value: rendered)
            }
            if let candidate = generated[name] ?? nil,
               !candidate.isEmpty,
               !projection.redactContent || generatedIdentityFields.contains(name) {
                return ProjectedField(name: name, value: candidate)
            }

            guard !projection.redactContent,
                  let value = arguments[name],
                  let sanitized = sanitize(value, excluding: excluded),
                  let rendered = renderJSONValue(sanitized),
                  !rendered.isEmpty
            else { return nil }
            return ProjectedField(name: name, value: rendered)
        }
    }

    package static func projectionDocument(_ fields: [ProjectedField]) -> String {
        fields.map { "\(fieldLabel($0.name)): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func argumentObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private static func sanitize(
        _ value: Any,
        excluding excluded: Set<String>
    ) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().reduce(into: [String: Any]()) { result, key in
                guard !excluded.contains(key.lowercased()),
                      let value = dictionary[key],
                      let child = sanitize(value, excluding: excluded)
                else { return }
                result[key] = child
            }
        case let array as [Any]:
            return array.compactMap { sanitize($0, excluding: excluded) }
        case is NSNull, is String, is NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }

    private static func renderJSONValue(_ value: Any) -> String? {
        if let string = value as? String { return clamp(string, limit: 8_000) }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return clamp(text, limit: 8_000)
    }

    private static func fieldLabel(_ field: String) -> String {
        let spaced = field.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func clamp(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

}
