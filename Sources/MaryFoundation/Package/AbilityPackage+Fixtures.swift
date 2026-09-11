//
//  AbilityPackage+Fixtures.swift
//  MaryFoundation
//
//  WHAT: Adding a route fixture to a package — one implementation, two benches.
//  IN:   Ability Studio's rehearsal sheet; Sand's roster pane
//  OUT:  a package with one more sentence in its corpus
//  PIN:  A ROUTE FIXTURE IS THE ONLY LEVER THAT MOVES THE SKILL TIER. An
//        ability's phrases feed the ability tier alone, so they can never
//        separate two skills inside one ability — a whole spoken sentence
//        naming the skill can, because `SemanticSkillRequestIndex` reads route
//        fixtures straight into that skill's corpus.
//        SHARED BECAUSE BOTH BENCHES LEARN THE SAME LESSON. The Studio could
//        keep a sentence and Sand could not, so the tool that runs real turns —
//        the one where a mis-route actually shows up — was the one that could
//        not record what it found.
//

import Foundation

public extension MaryAbilityPackage {

    /// The same package with `utterance` recorded as a `route` fixture naming
    /// `expectedSkill`, or unchanged when it already says so.
    ///
    /// `targetClass` is what was in front when the sentence was said — a
    /// fixture without one is a claim about no particular surface, which is
    /// weaker and, for a target-class-gated ability, untestable.
    func addingFixture(
        utterance: String,
        expectedSkill: SkillID?,
        targetClass: String? = nil
    ) -> MaryAbilityPackage {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        // SAID ONCE. A corpus with the same sentence twice is the same corpus
        // and a longer file.
        guard !fixtures.contains(where: {
            $0.utterance.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return self }

        var copy = self
        copy.fixtures.append(AbilityFixture(
            id: Self.fixtureID(for: trimmed, avoiding: Set(fixtures.map(\.id))),
            utterance: trimmed,
            expectedSkill: expectedSkill,
            targetClass: targetClass,
            expectedDisposition: .route))
        return copy
    }

    /// A readable, stable, unique id from the sentence itself.
    static func fixtureID(for utterance: String, avoiding taken: Set<String>) -> String {
        let words = utterance.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let stem = String(words)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let base = String((stem.isEmpty ? "fixture" : stem).prefix(80))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
