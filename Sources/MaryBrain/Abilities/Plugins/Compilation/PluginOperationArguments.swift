import MaryFoundation
import Foundation

/// The argument contract of Mary's data-only Dynamic recipe interpreter:
/// unknown keys reject, required inputs resolve or fail, and every value
/// satisfies its declared kind and bounds.
enum PluginOperationArguments {
    static func resolve(
        _ arguments: [String: String],
        for operation: PluginOperationSchema,
        planInput: String? = nil
    ) throws -> [String: String] {
        let declarations = Dictionary(
            operation.inputs.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        if let unknown = arguments.keys.sorted().first(where: { declarations[$0] == nil }) {
            throw PluginManagedUIError.unknownInput(unknown)
        }
        var resolved: [String: String] = [:]
        for input in operation.inputs {
            let value = arguments[input.name] ?? input.defaultValue
            guard let value else {
                if input.required { throw PluginManagedUIError.missingInput(input.name) }
                continue
            }
            let valid = isValid(value, for: input)
            guard valid else {
                throw PluginManagedUIError.invalidInput(input.name)
            }
            resolved[input.name] = value
        }
        return resolved
    }

    static func isValid(
        _ value: String,
        for input: PluginOperationInputSchema
    ) -> Bool {
        switch input.kind {
        case .text:
            guard !value.isEmpty,
                  value.utf8.count <= PluginValidator.maximumTextBytes,
                  value.unicodeScalars.allSatisfy({
                      $0.value >= 0x20 && $0.value != 0x7f
                  }) else { return false }
            return input.enumValues.isEmpty || input.enumValues.contains(value)
        case .number:
            guard let number = Double(value), number.isFinite else { return false }
            return (input.minimum.map { number >= $0 } ?? true)
                && (input.maximum.map { number <= $0 } ?? true)
        case .integer:
            guard let number = Int(value) else { return false }
            let converted = Double(number)
            return (input.minimum.map { converted >= $0 } ?? true)
                && (input.maximum.map { converted <= $0 } ?? true)
        case .boolean:
            return value == "true" || value == "false"
        }
    }
}
