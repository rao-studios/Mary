//
//  PluginValidator+ProseSurface.swift
//  MaryFoundation
//
//  WHAT: Prose-surface cost (cadence, excerpt) and collision (handle prefix) bounds.
//  IN:   PluginValidator.validate.
//  OUT:  SchemaIssue. Cross-package prefixes: PluginGraphValidator.
//

import Foundation

public extension PluginValidator {

    /// Cadence floors. Below this is a busy loop against another process's AX.
    static let minimumProseActiveSeconds: Double = 1
    static let minimumProseIdleSeconds: Double = 2
    static let maximumProseWatchSeconds: Double = 300

    /// Read ceilings. Asked reads generous; ambientExcerpt is not.
    static let maximumProseWholeDocumentCharacters = 200_000
    static let maximumProseRegionCharacters = 50_000
    static let maximumProseAmbientExcerptCharacters = 2_000

    /// Max editor roles before concluding the window holds no document.
    static let maximumProseEditorRoles = 4

    /// Spoken document noun — a word or two, never a payload.
    static let maximumProseDocumentNounBytes = 32

    static func validateProseSurface(
        _ surface: PluginProseSurfaceSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).proseSurface"

        // One upper-case letter. Multi-char / lower-case prefixes collide when spoken.
        let prefix = surface.handlePrefix
        if prefix.count != 1
            || !(prefix.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false) {
            error(
                "invalid-prose-handle-prefix",
                "\(path).handlePrefix",
                "A handle prefix is exactly one upper-case letter, so a spoken handle like [W2] stays unambiguous.")
        }

        // At least one role — empty would fail later as "no document open".
        if surface.editorRoles.isEmpty {
            error(
                "missing-prose-editor-role",
                "\(path).editorRoles",
                "Declare at least one Accessibility role to descend to; without one the document can never be located.")
        }
        if surface.editorRoles.count > maximumProseEditorRoles {
            error(
                "too-many-prose-editor-roles",
                "\(path).editorRoles",
                "A prose surface may name at most \(maximumProseEditorRoles) editor roles.")
        }
        for duplicate in Set(surface.editorRoles.filter { role in
            surface.editorRoles.filter { $0 == role }.count > 1
        }) {
            error(
                "duplicate-prose-editor-role",
                "\(path).editorRoles",
                "Editor role \(duplicate.rawValue) appears more than once.")
        }
        // Text-holding roles only. Else a button where a document was promised.
        for (index, role) in surface.editorRoles.enumerated()
        where !proseCapableRoles.contains(role) {
            error(
                "unsupported-prose-editor-role",
                "\(path).editorRoles[\(index)]",
                "Role \(role.rawValue) holds no editable text; a prose surface descends to a text area or text field.")
        }

        validateProseNoun(
            surface.documentNoun.singular,
            path: "\(path).documentNoun.singular",
            error: error)
        validateProseNoun(
            surface.documentNoun.plural,
            path: "\(path).documentNoun.plural",
            error: error)

        // Chord without modifier is a typed character. Bare "n" types n.
        for (name, chord) in surface.chords where chord.modifiers.isEmpty {
            error(
                "unmodified-prose-chord",
                "\(path).chords.\(name.rawValue)",
                "A chord needs at least one modifier; an unmodified key is typed into the document rather than issued as a command.")
        }
        for (name, chord) in surface.chords {
            for duplicate in Set(chord.modifiers.filter { modifier in
                chord.modifiers.filter { $0 == modifier }.count > 1
            }) {
                error(
                    "duplicate-prose-chord-modifier",
                    "\(path).chords.\(name.rawValue).modifiers",
                    "Modifier \(duplicate.rawValue) appears more than once.")
            }
        }

        let watch = surface.watch
        if !(watch.activeSeconds.isFinite && watch.activeSeconds >= minimumProseActiveSeconds
            && watch.activeSeconds <= maximumProseWatchSeconds) {
            error(
                "invalid-prose-watch-cadence",
                "\(path).watch.activeSeconds",
                "An active cadence is between \(minimumProseActiveSeconds) and \(maximumProseWatchSeconds) seconds.")
        }
        if !(watch.idleSeconds.isFinite && watch.idleSeconds >= minimumProseIdleSeconds
            && watch.idleSeconds <= maximumProseWatchSeconds) {
            error(
                "invalid-prose-watch-cadence",
                "\(path).watch.idleSeconds",
                "An idle cadence is between \(minimumProseIdleSeconds) and \(maximumProseWatchSeconds) seconds.")
        }
        // Idle must not be busier than active.
        if watch.idleSeconds.isFinite, watch.activeSeconds.isFinite,
           watch.idleSeconds < watch.activeSeconds {
            error(
                "inverted-prose-watch-cadence",
                "\(path).watch.idleSeconds",
                "The idle cadence must be no busier than the active one.")
        }

        let budgets = surface.budgets
        validateProseBudget(
            budgets.wholeDocumentCharacters,
            limit: maximumProseWholeDocumentCharacters,
            path: "\(path).budgets.wholeDocumentCharacters",
            error: error)
        validateProseBudget(
            budgets.regionCharacters,
            limit: maximumProseRegionCharacters,
            path: "\(path).budgets.regionCharacters",
            error: error)
        validateProseBudget(
            budgets.ambientExcerptCharacters,
            limit: maximumProseAmbientExcerptCharacters,
            path: "\(path).budgets.ambientExcerptCharacters",
            error: error)
    }

    /// The Accessibility roles that can actually hold editable prose.
    static var proseCapableRoles: Set<PluginAccessibilityRole> {
        [.textArea, .textField]
    }

    private static func validateProseNoun(
        _ noun: String,
        path: String,
        error: (String, String, String) -> Void
    ) {
        let trimmed = noun.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed != noun {
            error(
                "invalid-prose-document-noun",
                path,
                "A document noun is a nonempty word with no surrounding whitespace — Mary says it aloud.")
            return
        }
        if noun.utf8.count > maximumProseDocumentNounBytes {
            error(
                "invalid-prose-document-noun",
                path,
                "A document noun may contain at most \(maximumProseDocumentNounBytes) UTF-8 bytes.")
        }
        if noun.contains(where: { $0.isNewline }) {
            error(
                "invalid-prose-document-noun",
                path,
                "A document noun is one line.")
        }
    }

    private static func validateProseBudget(
        _ value: Int,
        limit: Int,
        path: String,
        error: (String, String, String) -> Void
    ) {
        guard value > 0, value <= limit else {
            error(
                "invalid-prose-budget",
                path,
                "A read budget is between 1 and \(limit) characters.")
            return
        }
    }
}
