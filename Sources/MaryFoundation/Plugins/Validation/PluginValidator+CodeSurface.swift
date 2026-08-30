//
//  PluginValidator+CodeSurface.swift
//  MaryFoundation
//
//  WHAT: Code-surface cost and collision bounds (read-only; no chords/watch).
//  IN:   PluginValidator.validate.
//  OUT:  SchemaIssue. Cross-package prefixes: PluginGraphValidator.
//  PIN:  Same read ceilings as PluginValidator+ProseSurface.
//

import Foundation

public extension PluginValidator {

    /// Same read ceilings as PluginValidator+ProseSurface.
    static let maximumCodeWholeDocumentCharacters = 200_000
    static let maximumCodeRegionCharacters = 50_000
    static let maximumCodeAmbientExcerptCharacters = 2_000

    /// Max editor roles before concluding the window holds no buffer.
    static let maximumCodeEditorRoles = 4

    static func validateCodeSurface(
        _ surface: PluginCodeSurfaceSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).codeSurface"

        // One upper-case letter. Same shape as +ProseSurface.
        let prefix = surface.handlePrefix
        if prefix.count != 1
            || !(prefix.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false) {
            error(
                "invalid-code-handle-prefix",
                "\(path).handlePrefix",
                "A handle prefix is exactly one upper-case letter, so a spoken handle stays unambiguous.")
        }

        // At least one role — empty would fail later as "no buffer open".
        if surface.editorRoles.isEmpty {
            error(
                "missing-code-editor-role",
                "\(path).editorRoles",
                "Declare at least one Accessibility role to descend to; without one the buffer can never be located.")
        }
        if surface.editorRoles.count > maximumCodeEditorRoles {
            error(
                "too-many-code-editor-roles",
                "\(path).editorRoles",
                "A code surface may name at most \(maximumCodeEditorRoles) editor roles.")
        }
        for duplicate in Set(surface.editorRoles.filter { role in
            surface.editorRoles.filter { $0 == role }.count > 1
        }) {
            error(
                "duplicate-code-editor-role",
                "\(path).editorRoles",
                "Editor role \(duplicate.rawValue) appears more than once.")
        }
        // Text-holding roles only.
        for (index, role) in surface.editorRoles.enumerated()
        where !codeCapableRoles.contains(role) {
            error(
                "unsupported-code-editor-role",
                "\(path).editorRoles[\(index)]",
                "Role \(role.rawValue) holds no editable text; a code surface descends to a text area or text field.")
        }

        let budgets = surface.budgets
        validateCodeBudget(
            budgets.wholeDocumentCharacters,
            limit: maximumCodeWholeDocumentCharacters,
            path: "\(path).budgets.wholeDocumentCharacters",
            error: error)
        validateCodeBudget(
            budgets.regionCharacters,
            limit: maximumCodeRegionCharacters,
            path: "\(path).budgets.regionCharacters",
            error: error)
        validateCodeBudget(
            budgets.ambientExcerptCharacters,
            limit: maximumCodeAmbientExcerptCharacters,
            path: "\(path).budgets.ambientExcerptCharacters",
            error: error)
    }

    /// Same text-holding roles as PluginValidator+ProseSurface.proseCapableRoles.
    static var codeCapableRoles: Set<PluginAccessibilityRole> {
        [.textArea, .textField]
    }

    private static func validateCodeBudget(
        _ value: Int,
        limit: Int,
        path: String,
        error: (String, String, String) -> Void
    ) {
        guard value > 0, value <= limit else {
            error(
                "invalid-code-budget",
                path,
                "A read budget is between 1 and \(limit) characters.")
            return
        }
    }
}
