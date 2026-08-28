//
//  CorpusAdmissionTests.swift
//  MaryFoundationTests
//
//  THE DECLARATION THAT REPLACES A LANGUAGE-SPECIFIC OBSERVER.
//
//  A `corpus` block is how a package describes the shape of its application's
//  project on disk — which files are units, what an edge between two of them
//  looks like, and which stylistic habits are worth a vote — so that one
//  generic producer can learn a codebase, a manuscript or a notebook without a
//  Swift file naming any of them.
//
//  IT IS THE ONE PLACE A PACKAGE HANDS MARY REGULAR EXPRESSIONS, and that is
//  what most of these tests are about. A pattern that does not compile, a
//  dimension that does not exist, a vote with one candidate — each is
//  well-formed JSON that decodes without complaint and then does nothing, for
//  as long as nobody thinks to check. The failure is not a crash; it is a
//  corpus that quietly never learns, which looks exactly like a corpus that
//  has not been used much yet. Refusing them at admission is what makes the
//  difference visible.
//
//  ROUND-TRIPPING IS PINNED for the same reason it is pinned for every other
//  block: the package digest is taken over these exact bytes, so an optional
//  that encodes as `null` when absent changes the digest of every package that
//  does not declare one.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct CorpusAdmissionTests {

    // MARK: - Helpers

    private func codes(_ corpus: PluginCorpusSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCorpus(corpus, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func pattern(_ expression: String) -> PluginCorpusCounter {
        .init(source: .pattern, pattern: expression)
    }

    /// A minimal corpus that admits cleanly — the baseline each test perturbs
    /// in exactly one way.
    private func valid(
        style: [PluginCorpusStyleRule] = [],
        include: [String] = ["swift"]
    ) -> PluginCorpusSchema {
        PluginCorpusSchema(
            include: include,
            notation: "swift",
            relations: .init(
                references: [#"\b([A-Z]\w*)\("#],
                declarations: [#"\bstruct\s+(\w+)"#]),
            style: style)
    }

    private func vote(
        _ dimension: String, _ first: String, _ second: String
    ) -> PluginCorpusStyleRule {
        .init(
            dimension: dimension,
            kind: .vote,
            candidates: [
                .init(value: first, counters: [pattern("a")]),
                .init(value: second, counters: [pattern("b")]),
            ])
    }

    // MARK: - The baseline

    @Test func aWellFormedCorpusAdmitsSilently() {
        #expect(codes(valid(style: [vote("bindingStyle", "guardEarlyReturn", "nestedConditional")]))
                .isEmpty)
    }

    // MARK: - Patterns

    /// THE HEADLINE RULE. A pattern that cannot compile is a rule that can
    /// never run, and the crawl would simply find one fewer edge — silently,
    /// forever.
    @Test func aPatternThatCannotCompileIsRefused() {
        let corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift",
            relations: .init(declarations: ["([A-Z"]))
        #expect(codes(corpus).contains("corpus-pattern-invalid"))
    }

    /// A relation names a thing; without a capture group the match says
    /// something is there without saying what, and nothing can be resolved.
    @Test func aRelationPatternMustCaptureTheNameItFinds() {
        let corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift",
            relations: .init(declarations: [#"\bstruct\s+\w+"#]))
        #expect(codes(corpus).contains("corpus-pattern-needs-capture"))
    }

    /// Pathological backtracking is a property of the expression, not of the
    /// input — so the input caps elsewhere do not cover this.
    @Test func anAbsurdlyLongPatternIsRefused() {
        let corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift",
            relations: .init(declarations: [
                "(" + String(repeating: "a|", count: 300) + "b)",
            ]))
        #expect(codes(corpus).contains("corpus-pattern-too-long"))
    }

    // MARK: - The corpus itself

    @Test func aCorpusThatMatchesNoFileIsRefused() {
        #expect(codes(valid(include: [])).contains("corpus-includes-nothing"))
    }

    @Test func extensionsAreWrittenWithoutALeadingDot() {
        #expect(codes(valid(include: [".swift"])).contains("corpus-include-malformed"))
    }

    /// References resolve THROUGH the declarations index. Declaring the first
    /// without the second makes every edge unresolvable, and the crawl stops
    /// after one hop in a way that looks like a small project.
    @Test func referencesWithoutDeclarationsAreRefused() {
        let corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift",
            relations: .init(references: [#"\b([A-Z]\w*)\("#]))
        #expect(codes(corpus).contains("corpus-references-without-declarations"))
    }

    // MARK: - The style vocabulary

    /// A dimension Mary does not know is a rule that can never be read back.
    @Test func anUnknownDimensionIsRefused() {
        #expect(codes(valid(style: [vote("vibes", "guardEarlyReturn", "nestedConditional")]))
                .contains("corpus-unknown-dimension"))
    }

    @Test func anUnknownStyleValueIsRefused() {
        #expect(codes(valid(style: [vote("bindingStyle", "guardEarlyReturn", "vibesBased")]))
                .contains("corpus-unknown-style-value"))
    }

    /// EVERY DIMENSION AND VALUE THE SHIPPED DECLARATION USES IS REAL. The
    /// wire format is strings so the schema need not move when the style
    /// vocabulary grows — which is exactly why a typo cannot be caught by the
    /// compiler and has to be caught here.
    @Test func everyKnownDimensionRoundTripsThroughItsRawValue() {
        for dimension in StyleDimension.allCases {
            #expect(StyleDimension(rawValue: dimension.rawValue) == dimension)
        }
    }

    // MARK: - Rule shape

    /// A vote between one alternative always votes the same way, which is not
    /// a measurement.
    @Test func aVoteNeedsSomethingToDecideBetween() {
        let rule = PluginCorpusStyleRule(
            dimension: "bindingStyle", kind: .vote,
            candidates: [.init(value: "guardEarlyReturn", counters: [pattern("a")])])
        #expect(codes(valid(style: [rule])).contains("corpus-vote-needs-alternatives"))
    }

    @Test func aCandidateWithNoCountersCanNeverWin() {
        let rule = PluginCorpusStyleRule(
            dimension: "bindingStyle", kind: .vote,
            candidates: [
                .init(value: "guardEarlyReturn", counters: [pattern("a")]),
                .init(value: "nestedConditional", counters: []),
            ])
        #expect(codes(valid(style: [rule])).contains("corpus-candidate-counts-nothing"))
    }

    @Test func aRatioWithoutAThresholdIsRefused() {
        let rule = PluginCorpusStyleRule(
            dimension: "accessDefault", kind: .ratio,
            numerator: pattern("public"), denominator: .init(source: .declaration),
            above: "publicByDefault")
        #expect(codes(valid(style: [rule])).contains("corpus-ratio-incomplete"))
    }

    /// A ratio with neither side computes a number and discards it.
    @Test func aRatioThatVotesNeitherWayIsRefused() {
        let rule = PluginCorpusStyleRule(
            dimension: "accessDefault", kind: .ratio,
            numerator: pattern("public"), denominator: .init(source: .declaration),
            threshold: 0.5)
        #expect(codes(valid(style: [rule])).contains("corpus-ratio-decides-nothing"))
    }

    /// A vocabulary is gathered from declared NAMES; a pattern counter would
    /// produce numbers with no words attached.
    @Test func aVocabularyRuleMustReadDeclaredNames() {
        let rule = PluginCorpusStyleRule(
            dimension: "roleVocabulary", kind: .vocabulary,
            vocabulary: pattern("Manager"))
        #expect(codes(valid(style: [rule])).contains("corpus-vocabulary-source-invalid"))
    }

    @Test func aSuffixCounterWithoutTokensIsRefused() {
        let rule = PluginCorpusStyleRule(
            dimension: "roleVocabulary", kind: .vocabulary,
            vocabulary: .init(source: .declaredTypeSuffix))
        #expect(codes(valid(style: [rule])).contains("corpus-counter-tokens-missing"))
    }

    /// A self-reference asks "is this name declared in this file" — with no
    /// capture group there is no name to ask about.
    @Test func aSelfReferenceCounterMustCaptureAName() {
        let rule = PluginCorpusStyleRule(
            dimension: "fileOrganization", kind: .vote,
            candidates: [
                .init(value: "extensionPerConcern", counters: [pattern("a")]),
                .init(value: "singleFileType", counters: [
                    .init(source: .selfReference, pattern: #"\bextension\s+\w+"#),
                ]),
            ])
        #expect(codes(valid(style: [rule])).contains("corpus-pattern-needs-capture"))
    }

    // MARK: - The wire

    @Test func aCorpusRoundTripsThroughItsOwnCoding() throws {
        let original = valid(style: [
            vote("bindingStyle", "guardEarlyReturn", "nestedConditional"),
            .init(
                dimension: "accessDefault", kind: .ratio,
                guardCondition: .init(numerator: .init(source: .declaration), atLeast: 4),
                numerator: pattern("public"),
                denominator: .init(source: .declaration),
                threshold: 0.5, above: "publicByDefault", below: "internalUnlessNeeded"),
            .init(
                dimension: "roleVocabulary", kind: .vocabulary,
                vocabulary: .init(source: .declaredTypeSuffix, tokens: ["Store"])),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PluginCorpusSchema.self, from: data) == original)
    }

    /// ABSENT STAYS ABSENT. The digest covers these bytes, so a default that
    /// encodes itself would change the digest of every package that leaves it
    /// out.
    @Test func defaultsDoNotAppearInTheEncoding() throws {
        let data = try JSONEncoder().encode(
            PluginCorpusSchema(include: ["swift"], notation: "swift"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("budgets"))
        #expect(!text.contains("exclude"))
        #expect(!text.contains("style"))
        #expect(!text.contains("relations"))
    }

    /// An unknown key inside the block would sit OUTSIDE the digest's reach if
    /// it were ignored — the whole reason the package decoder is strict.
    @Test func anUnknownKeyIsRefusedRatherThanIgnored() {
        let json = #"{"include":["swift"],"notation":"swift","tempo":"brisk"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                PluginCorpusSchema.self, from: Data(json.utf8))
        }
    }
}
