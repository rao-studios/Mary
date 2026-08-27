//
//  PluginValidator+Tokens.swift
//  MaryFoundation
//
//  THE LEAF RULES: what counts as a bounded alias, a printable literal, a
//  bundle identifier, a callable name. Every one of them is a hard bound on
//  bytes and alphabet, because these are the only places package-authored
//  strings reach the recipe interpreter.
//

import Foundation

extension PluginValidator {
    static func validateAliases(
        _ aliases: [String],
        path: String,
        error: (String, String, String) -> Void
    ) {
        if aliases.count > 32 {
            error("too-many-plugin-aliases", path, "A Plugin application may declare at most 32 aliases.")
        }
        for duplicate in duplicates(aliases) {
            error("duplicate-plugin-alias", path, "Alias \(duplicate) appears more than once.")
        }
        for (index, alias) in aliases.enumerated() {
            let words = alias.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            if words.isEmpty || words.count > 8 || alias != words.joined(separator: " ") {
                error(
                    "invalid-plugin-alias",
                    "\(path)[\(index)]",
                    "Plugin application aliases use one to eight lower-case words.")
            }
            if alias.utf8.count > 96 {
                error(
                    "plugin-alias-too-long",
                    "\(path)[\(index)]",
                    "A Plugin application alias may contain at most 96 UTF-8 bytes.")
            }
        }
    }

    static func validateInsets(
        _ insets: PluginWindowInsets,
        path: String,
        error: (String, String, String) -> Void
    ) {
        for (name, value) in [
            ("top", insets.top),
            ("leading", insets.leading),
            ("bottom", insets.bottom),
            ("trailing", insets.trailing),
        ] where !value.isFinite || value < 0 || value > 1_000 {
            error(
                "invalid-plugin-window-inset",
                "\(path).\(name)",
                "Content insets must be finite values between zero and 1000 points.")
        }
    }

    static func inputValueIsValid(
        _ value: String,
        for input: PluginOperationInputSchema
    ) -> Bool {
        switch input.kind {
        case .text:
            guard printableTextIsValid(value) else { return false }
            return input.enumValues.isEmpty || input.enumValues.contains(value)
        case .number:
            guard let number = Double(value), number.isFinite else { return false }
            return input.minimum.map { number >= $0 } ?? true
                && (input.maximum.map { number <= $0 } ?? true)
        case .integer:
            guard let number = Int(value) else { return false }
            let double = Double(number)
            return input.minimum.map { double >= $0 } ?? true
                && (input.maximum.map { double <= $0 } ?? true)
        case .boolean:
            return value == "true" || value == "false"
        }
    }

    static func printableTextIsValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumTextBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        }
    }

    static func boundedAccessibilityIdentifierIsValid(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumAccessibilityIdentifierBytes
            && value.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7f
            }
    }

    static func bundleIdentifierIsValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value.contains(".") else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
            }
        }
    }

    static func bundleNameIsValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBundleNameBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasSuffix(".app")
        else { return false }
        let stem = value.dropLast(4)
        guard !stem.isEmpty, stem != ".", stem != ".." else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
            .union(.newlines)
        return value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    static func applicationReleaseVersionIsValid(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumApplicationReleaseVersionBytes
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    static func callableNameIsValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.first?.isLowercase == true,
              value.last != "_",
              !value.contains("__") else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    static func duplicates<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var duplicates = Set<T>()
        for value in values where !seen.insert(value).inserted { duplicates.insert(value) }
        return Array(duplicates)
    }
}
