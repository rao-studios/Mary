import MaryBrain
import Foundation

struct AbilityStudioMachineTokenValidation: Equatable {
    let token: String?
    let message: String?

    var isValid: Bool { token != nil && message == nil }
}

/// Closed alias grammar; reject inner spaces/punctuation (token boundaries).
enum AbilityStudioMachineToken {
    static func validate(_ rawValue: String) -> AbilityStudioMachineTokenValidation {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !token.isEmpty else {
            return .init(token: nil, message: "Enter one artifact-kind word.")
        }
        guard token.utf8.count <= PluginValidator.maximumOperationAliasBytes else {
            return .init(
                token: nil,
                message: "Keep each synonym within \(PluginValidator.maximumOperationAliasBytes) ASCII characters.")
        }
        guard let first = token.utf8.first,
              (97...122).contains(first) else {
            return .init(
                token: nil,
                message: "Start the synonym with a letter from a through z.")
        }
        guard token.utf8.allSatisfy({ byte in
            (97...122).contains(byte) || (48...57).contains(byte)
        }) else {
            return .init(
                token: nil,
                message: "Use one word only: lowercase a-z and 0-9, with no spaces or punctuation.")
        }
        return .init(token: token, message: nil)
    }
}
