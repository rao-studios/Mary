//
//  UtteranceTemplate.swift
//  MaryFoundation
//
//  WHAT: `{application}` — the pragma slot an authored utterance may carry.
//  IN:   AbilityFixture.utterance, AbilityTriggerSchema phrases/tokens/seeds.
//  OUT:  the corpus builders, PackageRoutingFixtureTests, the validator.
//  PIN:  THE SAME CONVENTION `PluginCorpusStructureSchema` ALREADY USES —
//        single braces, a bare lowercase name, a CLOSED allow-list, and a
//        leftover brace is a validation error. Corpus path templates fill
//        `{project}` and `{id}` exactly this way; inventing a second dialect
//        for utterances would mean two things to learn and two to validate.
//  PIN:  `[X]` IS SAID OUT LOUD, `{x}` IS NEVER SAID. `[W2]` is a live window
//        handle Mary minted and a person repeats back. A brace is the opposite:
//        an author-time hole that must be filled before anybody hears the
//        sentence, which is why an unfilled one fails the package.
//

import Foundation

/// A pragma slot inside an authored utterance.
///
/// CLOSED ON PURPOSE. An open `{anything}` would be an interpreter for
/// package-authored instructions, which is the thing this whole design exists
/// to avoid — `PluginManagedUIExecutor` refuses the same for text expressions.
/// A new slot is a schema change here, not a parser change out there.
public enum UtteranceSlot: String, Codable, Hashable, Sendable, CaseIterable {
    /// An installed application this Ability can be pointed at — the SAME set
    /// `SkillRequirements.resolvesApplication` resolves over at run time. The
    /// author states the relationship; the roster supplies the names.
    case application
}

public enum UtteranceTemplate {

    /// Slots this text declares, in the order they appear, deduplicated.
    public static func slots(in text: String) -> [UtteranceSlot] {
        var seen = Set<UtteranceSlot>()
        var found: [UtteranceSlot] = []
        for name in placeholderNames(in: text) {
            guard let slot = UtteranceSlot(rawValue: name),
                  seen.insert(slot).inserted
            else { continue }
            found.append(slot)
        }
        return found
    }

    public static func hasSlots(_ text: String) -> Bool {
        !slots(in: text).isEmpty
    }

    /// Every brace name this text carries that is NOT a declared slot, plus the
    /// marker `"<unbalanced>"` when a brace never closes.
    ///
    /// THE VALIDATOR'S WHOLE CASE. A misspelled `{aplication}` is not a
    /// harmless typo: nothing expands it, so the sentence reaches the corpus
    /// with braces in it and matches nothing a person would ever say.
    public static func unknownPlaceholders(in text: String) -> [String] {
        var unknown: [String] = []
        if isUnbalanced(text) { unknown.append(unbalancedMarker) }
        for name in placeholderNames(in: text)
        where UtteranceSlot(rawValue: name) == nil {
            unknown.append(name)
        }
        return unknown
    }

    /// Reported in place of a name when a brace never closes.
    public static let unbalancedMarker = "<unbalanced>"

    /// Fill `{application}` with one application's spoken name.
    ///
    /// Literal replacement, never an expression engine — the same
    /// `replacingOccurrences` the corpus path templates use.
    public static func expand(_ text: String, application: String) -> String {
        text.replacingOccurrences(
            of: braced(UtteranceSlot.application.rawValue), with: application)
    }

    // MARK: - Parsing

    private static func braced(_ name: String) -> String { "{\(name)}" }

    /// Bare names inside single braces. A brace containing anything but
    /// lower-case letters, digits, `-` or `_` is not a placeholder at all and
    /// is left for `isUnbalanced` to judge.
    private static func placeholderNames(in text: String) -> [String] {
        var names: [String] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            guard let close = text[open...].firstIndex(of: "}") else { return names }
            let name = String(text[text.index(after: open)..<close])
            if !name.isEmpty, name.allSatisfy(isNameCharacter) {
                names.append(name)
            }
            index = text.index(after: close)
            if index >= text.endIndex { break }
        }
        return names
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLowercase && character.isLetter
            || character.isNumber
            || character == "-"
            || character == "_"
    }

    /// A brace that never closes, a `}` with no `{`, or a brace holding
    /// something that is not a name. All three leave a brace in the sentence.
    private static func isUnbalanced(_ text: String) -> Bool {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                guard depth == 0 else { return true }
                depth += 1
                // The braces are there; the content has to be a usable name.
                guard let close = text[index...].firstIndex(of: "}") else { return true }
                let name = String(text[text.index(after: index)..<close])
                if name.isEmpty || !name.allSatisfy(isNameCharacter) { return true }
            } else if character == "}" {
                guard depth == 1 else { return true }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return depth != 0
    }
}
