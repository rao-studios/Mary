//
//  SpokenArgumentExtractor.swift
//  MaryPlugin
//
//  WHAT: Peel a spoken command down to its argument payload — generalizes
//        SpokenTitleMatcher's hardcoded "open apple music and"/"in apple
//        music" special-casing into package-declared, any-platform peeling.
//  IN:   the raw utterance + the winning skill's OWN ability triggers +
//        the resolved application's OWN aliases
//  OUT:  EmbeddingRouting.argumentsJSON — the confidence-dispatch shortcut's
//        one required string parameter
//  PIN:  Never returns empty. Degrades to the least-stripped non-empty
//        stage, so a downstream Skill always has something honest to
//        resolve or refuse on.
//

import Foundation
import MaryAmbient
import MaryFoundation

public enum SpokenArgumentExtractor {

    /// 1. Generic leading grammar — `EditIntentClassifier.stripPreamble`,
    ///    reused, not duplicated.
    /// 2. A leading "open/launch <app aliases> and" clause — the app's own
    ///    aliases, never a hardcoded name.
    /// 3. ONE leading command phrase (`triggers.phrases`, longest first) or
    ///    token (`triggers.tokens`) — the SKILL'S OWN ability's package
    ///    data, never a hardcoded verb list.
    /// 4. Trailing "in/on <app aliases>" context — same real aliases.
    /// Each stage backs off to the previous stage's result rather than
    /// stripping down to nothing.
    public static func extract(
        _ utterance: String,
        triggers: AbilityTriggerSchema,
        applicationAliases: Set<String>
    ) -> String {
        let aliasWords = Set(applicationAliases.flatMap(letterWords))

        let stage1 = EditIntentClassifier.stripPreamble(
            utterance, applicationAliases: applicationAliases)
        guard let base1 = nonEmpty(stage1) else { return utterance }

        let stage2 = strippingLeadingOpenClause(base1, aliasWords: aliasWords)
        let base2 = nonEmpty(stage2) ?? base1

        let stage3 = strippingLeadingCommandPhrase(base2, triggers: triggers)
        let base3 = nonEmpty(stage3) ?? base2

        let stage4 = strippingTrailingAppContext(base3, aliasWords: aliasWords)
        let base4 = nonEmpty(stage4) ?? base3

        return base4
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func letterWords(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    // MARK: - Tokenizing with original ranges, so a peel can slice the
    // source string without losing its casing or inter-word punctuation.

    private struct Token {
        let lower: String
        let range: Range<String.Index>
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !text[index].isLetter {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, text[end].isLetter {
                end = text.index(after: end)
            }
            tokens.append(Token(lower: text[index..<end].lowercased(), range: index..<end))
            index = end
        }
        return tokens
    }

    // MARK: - Stage 2 — the app is being named as a destination, not a title.

    private static let openVerbs: Set<String> = ["open", "launch", "switch"]

    private static func strippingLeadingOpenClause(
        _ text: String, aliasWords: Set<String>
    ) -> String {
        guard !aliasWords.isEmpty else { return text }
        let tokens = tokenize(text)
        var cursor = 0
        guard cursor < tokens.count, openVerbs.contains(tokens[cursor].lower) else { return text }
        cursor += 1
        if cursor < tokens.count, tokens[cursor].lower == "to" { cursor += 1 }
        let aliasStart = cursor
        while cursor < tokens.count, aliasWords.contains(tokens[cursor].lower) {
            cursor += 1
        }
        guard cursor > aliasStart else { return text }
        guard cursor < tokens.count, tokens[cursor].lower == "and" else { return text }
        cursor += 1
        guard cursor < tokens.count else { return text }
        return String(text[tokens[cursor].range.lowerBound...])
    }

    // MARK: - Stage 3 — the skill's OWN command vocabulary, package data.

    private static func strippingLeadingCommandPhrase(
        _ text: String, triggers: AbilityTriggerSchema
    ) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        // Longest phrase first, so a longer match is never pre-empted by a
        // shorter one that happens to share a leading word.
        let phraseWordLists = triggers.phrases
            .map { letterWords(in: $0) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for phraseWords in phraseWordLists {
            guard tokens.count > phraseWords.count else { continue }
            guard zip(phraseWords, tokens).allSatisfy({ $0 == $1.lower }) else { continue }
            return String(text[tokens[phraseWords.count].range.lowerBound...])
        }
        let tokenSet = Set(triggers.tokens.map { $0.lowercased() })
        if tokens.count > 1, tokenSet.contains(tokens[0].lower) {
            return String(text[tokens[1].range.lowerBound...])
        }
        return text
    }

    // MARK: - Stage 4 — trailing "in/on <app>" names where, not what.

    private static let trailingConnectors: Set<String> = ["in", "on"]

    private static func strippingTrailingAppContext(
        _ text: String, aliasWords: Set<String>
    ) -> String {
        guard !aliasWords.isEmpty else { return text }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        var cursor = tokens.count
        var consumedAlias = false
        while cursor > 0, aliasWords.contains(tokens[cursor - 1].lower) {
            cursor -= 1
            consumedAlias = true
        }
        guard consumedAlias, cursor > 0,
              trailingConnectors.contains(tokens[cursor - 1].lower)
        else { return text }
        cursor -= 1
        guard cursor > 0 else { return text }
        return String(text[text.startIndex..<tokens[cursor - 1].range.upperBound])
    }
}
