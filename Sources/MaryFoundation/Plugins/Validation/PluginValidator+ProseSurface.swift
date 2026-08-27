//
//  PluginValidator+ProseSurface.swift
//  MaryFoundation
//
//  THE PROSE-SURFACE DECLARATION'S BOUNDS.
//
//  Nothing here reads a file or touches a screen — the declaration is
//  coordinates, so the rules that matter are cost rules and collision rules.
//
//  COST, because three of these numbers are spent on the user's behalf without
//  being asked: a watch cadence wakes the machine on a timer, and an ambient
//  excerpt is charged to the prompt budget on EVERY turn whether or not anyone
//  asked about that document. A package that could name its own cadence and
//  excerpt size could make every other application's perception late and every
//  turn more expensive, and neither cost would appear anywhere the user could
//  see it. So the package proposes and this file bounds.
//
//  COLLISION, because a handle prefix is a letter a person says out loud.
//  "[W2]" means one thing per session or it means nothing, and two packages
//  minting under the same letter is a bug the user experiences as Mary
//  reaching into the wrong window. The cross-package half of that check lives
//  in PluginGraphValidator, which is the only place that can see two packages
//  at once; here we can only insist the prefix is well formed.
//

import Foundation

public extension PluginValidator {

    /// Cadence floors. Below these a watcher stops being perception and starts
    /// being a busy loop against another process's Accessibility server.
    static let minimumProseActiveSeconds: Double = 1
    static let minimumProseIdleSeconds: Double = 2
    static let maximumProseWatchSeconds: Double = 300

    /// Read ceilings. `wholeDocument` and `region` bound a read the user asked
    /// for, so they are generous. `ambientExcerpt` bounds text that rides
    /// along uninvited, so it is not.
    static let maximumProseWholeDocumentCharacters = 200_000
    static let maximumProseRegionCharacters = 50_000
    static let maximumProseAmbientExcerptCharacters = 2_000

    /// The most editor roles worth trying before concluding the window holds
    /// no document.
    static let maximumProseEditorRoles = 4

    /// The document noun is spoken aloud in ambient sentences, so it is a word
    /// or two, never a payload.
    static let maximumProseDocumentNounBytes = 32

    static func validateProseSurface(
        _ surface: PluginProseSurfaceSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).proseSurface"

        // ONE UPPER-CASE LETTER. Handles are minted as prefix + ordinal and
        // read back by a person; a multi-character prefix makes "[Wd2]" and a
        // lower-case one makes two prefixes that sound identical.
        let prefix = surface.handlePrefix
        if prefix.count != 1
            || !(prefix.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false) {
            error(
                "invalid-prose-handle-prefix",
                "\(path).handlePrefix",
                "A handle prefix is exactly one upper-case letter, so a spoken handle like [W2] stays unambiguous.")
        }

        // AT LEAST ONE ROLE, because the adapter descends by role and an empty
        // list is a surface that can never be found — which would fail later,
        // at read time, as "no document open" rather than here as a malformed
        // package.
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
        // ROLES THAT HOLD TEXT. Every other role in the vocabulary describes a
        // control, and descending to one would find a button where a document
        // was promised.
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

        // A CHORD WITH NO MODIFIER IS A TYPED CHARACTER. `newDocument` bound to
        // bare "n" would type the letter n into whatever has focus, which is
        // the most confusing possible failure: it looks like Mary typed
        // something at random.
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
        // IDLE MUST NOT BE BUSIER THAN ACTIVE. Inverted, the two numbers say
        // "look harder once the user has stopped caring", which is the exact
        // opposite of what the pair is for.
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
