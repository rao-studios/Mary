import Foundation

/// Closed structural validation for Values. Descriptions and summaries never
/// participate; only declared shape, fields, enum cases, versions, privacy,
/// and referenced Value type identifiers affect acceptance.
public enum ValueEnvelopeValidator {
    public static func validate(
        _ envelope: ValueEnvelope,
        schemas: [ValueTypeSchema],
        at now: Date = Date()
    ) -> ValueEnvelopeValidation {
        let registry = Dictionary(
            schemas.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var issues: [ValueValidationIssue] = []
        guard let schema = registry[envelope.typeID] else {
            return .init(issues: [.init(
                path: "typeID",
                message: "Value type \(envelope.typeID.rawValue) is not present in the active Ability registry.")])
        }
        if envelope.schemaVersion != schema.version {
            issues.append(.init(
                path: "schemaVersion",
                message: "Value uses schema \(envelope.schemaVersion.rawValue), but the active type is \(schema.version.rawValue)."))
        }
        if !envelope.isFresh(at: now) {
            issues.append(.init(path: "expiresAt", message: "Value is not fresh at the validation time."))
        }
        validate(
            envelope.value,
            as: schema,
            registry: registry,
            path: "value",
            privacy: envelope.privacy,
            ancestors: [],
            issues: &issues)
        return .init(issues: issues)
    }

    private static func validate(
        _ value: MaryValue,
        as schema: ValueTypeSchema,
        registry: [ValueTypeID: ValueTypeSchema],
        path: String,
        privacy: DataPrivacyClass,
        ancestors: Set<ValueTypeID>,
        issues: inout [ValueValidationIssue]
    ) {
        if ancestors.contains(schema.id) {
            issues.append(.init(path: path, message: "Recursive Value schemas are not supported at runtime."))
            return
        }
        let nextAncestors = ancestors.union([schema.id])
        switch (schema.shape, value) {
        case (.string, .string), (.boolean, .boolean), (.integer, .integer), (.data, .data):
            break
        case (.number, .number(let number)):
            if !number.isFinite {
                issues.append(.init(path: path, message: "Numbers must be finite."))
            }
        case (.number, .integer):
            // Integers are an exact subset of JSON numbers.
            break
        case (.enumeration, .string(let member)):
            if !schema.enumValues.contains(member) {
                issues.append(.init(path: path, message: "\(member) is not a declared enumeration value."))
            }
        case (.object, .object(let object)):
            let fields = Dictionary(
                schema.fields.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first })
            for field in schema.fields where field.required && object[field.name] == nil {
                issues.append(.init(path: "\(path).\(field.name)", message: "Required field is missing."))
            }
            for key in object.keys where fields[key] == nil {
                issues.append(.init(path: "\(path).\(key)", message: "Field is not declared by \(schema.id.rawValue)."))
            }
            for (name, child) in object {
                guard let field = fields[name] else { continue }
                if privacy.rank < field.privacy.rank {
                    issues.append(.init(
                        path: "\(path).\(name)",
                        message: "Envelope privacy is weaker than the field's \(field.privacy.rawValue) classification."))
                }
                guard let childSchema = registry[field.valueType] else {
                    issues.append(.init(
                        path: "\(path).\(name)",
                        message: "Referenced Value type \(field.valueType.rawValue) is not active."))
                    continue
                }
                validate(
                    child,
                    as: childSchema,
                    registry: registry,
                    path: "\(path).\(name)",
                    privacy: privacy,
                    ancestors: nextAncestors,
                    issues: &issues)
            }
        case (.array, .array(let array)):
            guard let itemType = schema.itemType,
                  let itemSchema = registry[itemType]
            else {
                issues.append(.init(path: path, message: "Array Value type has no active item schema."))
                return
            }
            for (index, child) in array.enumerated() {
                validate(
                    child,
                    as: itemSchema,
                    registry: registry,
                    path: "\(path)[\(index)]",
                    privacy: privacy,
                    ancestors: nextAncestors,
                    issues: &issues)
            }
        default:
            issues.append(.init(
                path: path,
                message: "Payload shape does not match \(schema.id.rawValue) (\(schema.shape.rawValue))."))
        }
    }
}

private extension DataPrivacyClass {
    var rank: Int {
        switch self {
        case .publicDefinition: return 0
        case .private: return 1
        case .sensitive: return 2
        case .secret: return 3
        }
    }
}
