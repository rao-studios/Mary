//
//  CorpusStyleReaderTests.swift
//  MaryPluginTests
//
//  WHAT: Shipped xcode.mary corpus style rules match expected evidence.
//  OUT:  CorpusStyleReader over Abilities/xcode.mary
//

import Foundation
import MaryAmbient
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct CorpusStyleReaderTests {

    // MARK: - The shipped declaration

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryAdaptersTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// The real corpus block, out of the real package file.
    static let corpus: PluginCorpusSchema? = {
        let url = repositoryRoot
            .appendingPathComponent("Abilities/xcode.mary")
        guard let data = try? Data(contentsOf: url),
              let package = try? AbilityPackageCodec.decode(data)
        else { return nil }
        return package.plugin?.corpus
    }()

    private func read(_ source: String, filename: String = "Demo.swift") -> [StyleObservation] {
        guard let corpus = Self.corpus else { return [] }
        let text = CorpusText(source: source, filename: filename)
        let declared = corpus.relations.declarations.flatMap {
            CorpusPatterns.captures($0, in: text.code)
        }
        return CorpusStyleReader.observe(
            text: text, declaredTypes: declared, corpus: corpus)
    }

    private func value(
        _ observations: [StyleObservation], _ dimension: StyleDimension
    ) -> StyleValue? {
        observations.first { $0.dimension == dimension }?.value
    }

    @Test func theShippedPackageDeclaresACorpus() throws {
        let corpus = try #require(
            Self.corpus, "xcode.mary must declare a corpus for these goldens to mean anything")
        #expect(corpus.notation == "swift")
        #expect(corpus.include.contains("swift"))
        #expect(!corpus.style.isEmpty)
    }

    // MARK: - Goldens, one per translated detector

    @Test func lockBoxesOutvoteActors() {
        let source = """
        struct A {
            private let one = OSAllocatedUnfairLock<Int>(initialState: 0)
            private let two = OSAllocatedUnfairLock<Int>(initialState: 0)
            private let three = NSLock()
        }
        """
        #expect(value(read(source), .concurrencyPrimitive) == .lockBox)
    }

    /// The ratio, not the count — the whole reason this rule is a ratio.

    /// A MODIFIER BETWEEN `public` AND THE KEYWORD STILL MAKES IT PUBLIC.
    /// The first translation of this rule matched `public` only when the
    /// declaration keyword followed it immediately, so `public static let` and
    /// `public final class` counted as internal — seven of the twenty-four
    /// public declarations in one real file, enough to flip its vote. The
    /// compiled observer this descends from carried an explicit modifier set
    /// for exactly this and the regex had quietly dropped it. Found by reading
    /// a live crawl's output and disbelieving it.

    /// LOCAL BINDINGS ARE NOT DECLARATIONS WITH AN ACCESS LEVEL, and counting
    /// them sank this rule on real code. A working file is mostly `let` inside
    /// function bodies — 56 of 74 in the first file this was run against — so a
    /// denominator of "every declaration keyword" measured a 24-public API file
    /// at 0.32 and called it internal. The denominator is now the declarations
    /// that COULD carry an access level: anything with an explicit modifier,
    /// plus types and functions.

    /// A `+` in the name is evidence FOR splitting a type across files.

    /// AND THE SCAR THIS RULE CARRIES: an ordinary small file must abstain.
    /// Counting every one of them as a vote for "keeps a type whole" measured
    /// the source codebase at 90% confident of the opposite of its real
    /// convention.

    /// A NON-TEST FILE MUST NOT VOTE on test dimensions, or every source file
    /// in the project files an opinion about test naming.

    // MARK: - The `func` declaration pattern (`[Corpus T]`)

    /// THE SHIPPED PATTERN, PROVEN AGAINST REAL SOURCE — `declarations`
    /// used to name only types; this pins that its `func` sibling, added
    /// for the outline Skill, captures alongside it rather than replacing
    /// it or silently failing to compile.

    /// A LOCAL FUNCTION IS NOT EXCLUDED — deliberately. The pattern is a
    /// flat scan with no nesting awareness, the same shape the existing
    /// type pattern already has (a struct nested inside another struct
    /// matches too), so a local helper shows up in the outline exactly
    /// like a top-level one. That is an accepted property of a regex-based
    /// outline, not a bug: telling "top-level" from "local" needs brace
    /// depth, which needs a parser, and this is deliberately not one.

    /// `function` MUST NOT MATCH AS `func` — the pattern's own word
    /// boundary is the only thing standing between "found a declaration"
    /// and "found four characters of an unrelated identifier".

    // MARK: - Abstention

    /// A tie is silence, not a coin flip.

    // MARK: - The masking the rules depend on

    /// The reason `CorpusText` exists: commentary must not be counted as code.

    /// And a word inside a string literal is neither: counting `guard` in an
    /// error message as a binding style is a file voting for a habit it does
    /// not have.

    /// Line structure survives masking, because the comment-density counter is
    /// line-anchored and would otherwise see one enormous line.

    /// An unterminated quote must not swallow the rest of the file.
}
