//
//  PluginValidator+CodeSurface.swift
//  MaryFoundation
//
//  THE CODE-SURFACE DECLARATION'S BOUNDS.
//
//  Nothing here reads a file or touches a screen — the declaration is
//  coordinates, so the rules that matter are cost rules and collision rules,
//  the same two families `PluginValidator+ProseSurface` checks for its own
//  declaration. Half of that file's rules do not apply here: there is no
//  chord to demand a modifier for and no watch cadence to floor, because a
//  code surface is read-only and declares neither (see
//  `PluginCodeSurfaceSchema`'s header for why).
//
//  COST, because a read budget bounds how much text crosses the boundary in
//  one call, and an ambient excerpt — were anything reading it yet — would be
//  charged to the prompt on every turn. So the package proposes and this file
//  bounds, at the same ceilings the prose family uses: a source file is not
//  categorically smaller than a manuscript chapter.
//
//  COLLISION, because a handle prefix is a letter a person says out loud, and
//  it mints from the SAME namespace `PluginProseSurfaceSchema.handlePrefix`
//  does. The cross-package half of that check lives in `PluginGraphValidator`,
//  which checks both families' prefixes together; here we can only insist
//  this package's own prefix is well formed.
//

import Foundation

public extension PluginValidator {

    /// Read ceilings, at the same numbers `PluginValidator+ProseSurface`
    /// uses — a source file earns no smaller an allowance than a manuscript
    /// chapter.
    static let maximumCodeWholeDocumentCharacters = 200_000
    static let maximumCodeRegionCharacters = 50_000
    static let maximumCodeAmbientExcerptCharacters = 2_000

    /// The most editor roles worth trying before concluding the window holds
    /// no buffer.
    static let maximumCodeEditorRoles = 4

    static func validateCodeSurface(
        _ surface: PluginCodeSurfaceSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).codeSurface"

        // ONE UPPER-CASE LETTER, for the same reason
        // `PluginValidator+ProseSurface` insists on one: a spoken handle like
        // "[C2]" stays unambiguous only if the prefix is exactly this shape.
        let prefix = surface.handlePrefix
        if prefix.count != 1
            || !(prefix.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false) {
            error(
                "invalid-code-handle-prefix",
                "\(path).handlePrefix",
                "A handle prefix is exactly one upper-case letter, so a spoken handle stays unambiguous.")
        }

        // AT LEAST ONE ROLE — an empty list is a surface that can never be
        // found, which would otherwise fail later, at read time, as "no
        // buffer open" rather than here as a malformed package.
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
        // ROLES THAT HOLD TEXT. Every other role in the vocabulary describes
        // a control, and descending to one would find a button where a
        // buffer was promised.
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

    /// The Accessibility roles that can actually hold editable text — the
    /// same set `PluginValidator+ProseSurface.proseCapableRoles` names,
    /// because the underlying question ("does this role hold text at all")
    /// does not change between the two families.
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
