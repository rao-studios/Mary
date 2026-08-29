//
//  CorpusStyleReaderTests.swift
//  MaryPluginTests
//
//  DOES THE DECLARATION SAY WHAT THE COMPILED OBSERVER SAID?
//
//  The riskiest thing in this whole port is not the interpreter — it is the
//  TRANSLATION: eleven rules that used to be Swift functions, rewritten as
//  regular expressions in a `.mary` file by hand. A mistranslated pattern does
//  not fail. It votes, quietly and wrongly, and the profile it builds is
//  confidently backwards — which is precisely the failure the source observer
//  hit twice and left comments about.
//
//  So these tests run the SHIPPED DECLARATION over source fixtures whose right
//  answer is obvious by inspection. Not a hand-built rule set: the actual
//  bytes of `Abilities/xcode.mary`, decoded through the real package codec, so
//  a bad edit to that file fails here rather than in six months of skewed
//  evidence.
//
//  The fixtures are deliberately small and lopsided. A file with four lock
//  boxes and no actors is not a realistic file; it is an unambiguous question,
//  which is what a golden test should ask.
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

    @Test func anActorFileVotesForActors() {
        let source = """
        actor Keeper {
            func hold() {}
        }
        actor Watcher {
            func look() {}
        }
        """
        #expect(value(read(source), .concurrencyPrimitive) == .actor)
    }

    @Test func guardsOutvoteIfLets() {
        let source = """
        struct A {
            func run(_ x: Int?) {
                guard let x else { return }
                guard let y = also(x) else { return }
                guard case .some = maybe() else { return }
            }
        }
        """
        #expect(value(read(source), .bindingStyle) == .guardEarlyReturn)
    }

    @Test func publishedPropertiesAreSeenAsExposedState() {
        let source = """
        final class Model {
            @Published var one = 0
            @Published var two = 0
            @Observable var three = 0
        }
        """
        #expect(value(read(source), .stateExposure) == .publishedProperties)
    }

    /// The ratio, not the count — the whole reason this rule is a ratio.
    @Test func aMostlyPublicFileLeansPublic() {
        let source = """
        public struct A {
            public func one() {}
            public func two() {}
            public var three = 0
            func hidden() {}
        }
        """
        #expect(value(read(source), .accessDefault) == .publicByDefault)
    }

    /// A MODIFIER BETWEEN `public` AND THE KEYWORD STILL MAKES IT PUBLIC.
    /// The first translation of this rule matched `public` only when the
    /// declaration keyword followed it immediately, so `public static let` and
    /// `public final class` counted as internal — seven of the twenty-four
    /// public declarations in one real file, enough to flip its vote. The
    /// compiled observer this descends from carried an explicit modifier set
    /// for exactly this and the regex had quietly dropped it. Found by reading
    /// a live crawl's output and disbelieving it.
    @Test func modifiersBetweenPublicAndTheKeywordStillCountAsPublic() {
        let source = """
        public final class A {
            public static let one = 0
            public private(set) var two = 0
            public static func three() {}
            func hidden() {}
        }
        """
        #expect(value(read(source), .accessDefault) == .publicByDefault)
    }

    /// LOCAL BINDINGS ARE NOT DECLARATIONS WITH AN ACCESS LEVEL, and counting
    /// them sank this rule on real code. A working file is mostly `let` inside
    /// function bodies — 56 of 74 in the first file this was run against — so a
    /// denominator of "every declaration keyword" measured a 24-public API file
    /// at 0.32 and called it internal. The denominator is now the declarations
    /// that COULD carry an access level: anything with an explicit modifier,
    /// plus types and functions.
    @Test func localBindingsDoNotDiluteTheAccessRatio() {
        let source = """
        public struct A {
            public func one() {
                let a = 1
                let b = 2
                let c = 3
                var d = 4
                let e = 5
                use(a, b, c, d, e)
            }
            public func two() {}
            func hidden() {}
        }
        """
        #expect(value(read(source), .accessDefault) == .publicByDefault)
    }

    @Test func aMostlyInternalFileLeansInternal() {
        let source = """
        struct A {
            func one() {}
            func two() {}
            func three() {}
            var four = 0
            struct B {}
            enum C {}
        }
        """
        #expect(value(read(source), .accessDefault) == .internalUnlessNeeded)
    }

    /// A `+` in the name is evidence FOR splitting a type across files.
    @Test func aPlusInTheFilenameVotesForSplitting() {
        let source = """
        extension Parser {
            func extra() {}
        }
        """
        #expect(value(read(source, filename: "Parser+Extra.swift"), .fileOrganization)
                == .extensionPerConcern)
    }

    /// AND THE SCAR THIS RULE CARRIES: an ordinary small file must abstain.
    /// Counting every one of them as a vote for "keeps a type whole" measured
    /// the source codebase at 90% confident of the opposite of its real
    /// convention.
    @Test func anOrdinarySmallFileHasNoOpinionOnOrganisation() {
        let source = """
        struct Small {
            let value: Int
        }
        """
        #expect(value(read(source), .fileOrganization) == nil)
    }

    @Test func testFilesAreRecognisedByFramework() {
        let source = """
        import Testing
        @Suite struct Thing {
            @Test func itWorks() { #expect(true) }
        }
        """
        #expect(value(read(source, filename: "ThingTests.swift"), .testFramework) == .swiftTesting)
    }

    /// A NON-TEST FILE MUST NOT VOTE on test dimensions, or every source file
    /// in the project files an opinion about test naming.
    @Test func anOrdinaryFileNeverVotesOnTestDimensions() {
        let source = """
        import Testing
        struct Thing {
            func itWorks() {}
        }
        """
        let observations = read(source, filename: "Thing.swift")
        #expect(value(observations, .testFramework) == nil)
        #expect(value(observations, .testNaming) == nil)
    }

    @Test func sentenceShapedTestNamesAreRecognised() {
        let source = """
        import Testing
        @Suite struct S {
            @Test func cacheEvictsTheOldestEntryFirst() {}
            @Test func retryStopsAfterTheThirdFailure() {}
        }
        """
        #expect(value(read(source, filename: "STests.swift"), .testNaming) == .sentence)
    }

    @Test func roleSuffixesBecomeAVocabulary() {
        let source = """
        struct ThingStore {}
        struct OtherProvider {}
        struct PlainName {}
        """
        let observation = read(source).first { $0.dimension == .roleVocabulary }
        #expect(observation?.vocabulary.sorted() == ["provider", "store"])
    }

    // MARK: - The `func` declaration pattern (`[Corpus T]`)

    /// THE SHIPPED PATTERN, PROVEN AGAINST REAL SOURCE — `declarations`
    /// used to name only types; this pins that its `func` sibling, added
    /// for the outline Skill, captures alongside it rather than replacing
    /// it or silently failing to compile.
    @Test func theShippedDeclarationsPatternCapturesFunctionsToo() throws {
        let corpus = try #require(Self.corpus)
        let source = """
        struct Greeter {
            func hello() -> String { "hi" }
            static func loud() {}
        }
        func topLevel() {}
        """
        let names = corpus.relations.declarations.flatMap {
            CorpusPatterns.captures($0, in: source)
        }
        #expect(Set(names) == Set(["Greeter", "hello", "loud", "topLevel"]))
    }

    /// A LOCAL FUNCTION IS NOT EXCLUDED — deliberately. The pattern is a
    /// flat scan with no nesting awareness, the same shape the existing
    /// type pattern already has (a struct nested inside another struct
    /// matches too), so a local helper shows up in the outline exactly
    /// like a top-level one. That is an accepted property of a regex-based
    /// outline, not a bug: telling "top-level" from "local" needs brace
    /// depth, which needs a parser, and this is deliberately not one.
    @Test func aLocalFunctionIsIncludedNotExcluded() throws {
        let corpus = try #require(Self.corpus)
        let source = """
        func outer() {
            func inner() {}
            inner()
        }
        """
        let names = corpus.relations.declarations.flatMap {
            CorpusPatterns.captures($0, in: source)
        }
        #expect(names.contains("outer"))
        #expect(names.contains("inner"))
    }

    /// `function` MUST NOT MATCH AS `func` — the pattern's own word
    /// boundary is the only thing standing between "found a declaration"
    /// and "found four characters of an unrelated identifier".
    @Test func theWordFunctionIsNotMistakenForTheFuncKeyword() throws {
        let corpus = try #require(Self.corpus)
        let source = "let function = 1\n"
        let names = corpus.relations.declarations.flatMap {
            CorpusPatterns.captures($0, in: source)
        }
        #expect(names.isEmpty)
    }

    // MARK: - Abstention

    @Test func anEmptyFileSaysNothing() {
        #expect(read("").isEmpty)
    }

    /// A tie is silence, not a coin flip.
    @Test func balancedEvidenceProducesNoVote() {
        let source = """
        struct A {
            func run(_ x: Int?) {
                guard let x else { return }
                if let y = x.other { use(y) }
            }
        }
        """
        #expect(value(read(source), .bindingStyle) == nil)
    }

    // MARK: - The masking the rules depend on

    /// The reason `CorpusText` exists: commentary must not be counted as code.
    @Test func aWordInsideACommentIsNotCode() {
        let text = CorpusText(
            source: "// this throws sometimes\nlet a = 1\n", filename: "A.swift")
        #expect(CorpusPatterns.count(#"\bthrows\b"#, in: text.code) == 0)
        #expect(CorpusPatterns.count(#"\bthrows\b"#, in: text.comments) == 1)
    }

    /// And a word inside a string literal is neither: counting `guard` in an
    /// error message as a binding style is a file voting for a habit it does
    /// not have.
    @Test func aWordInsideAStringIsNeitherCodeNorComment() {
        let text = CorpusText(
            source: "let message = \"guard the door\"\n", filename: "A.swift")
        #expect(CorpusPatterns.count(#"\bguard\b"#, in: text.code) == 0)
        #expect(CorpusPatterns.count(#"\bguard\b"#, in: text.comments) == 0)
    }

    /// Line structure survives masking, because the comment-density counter is
    /// line-anchored and would otherwise see one enormous line.
    @Test func lineStructureSurvivesMasking() {
        let text = CorpusText(
            source: "// one\n// two\nlet a = 1\n", filename: "A.swift")
        #expect(text.comments.filter { $0 == "\n" }.count == 3)
        #expect(text.code.filter { $0 == "\n" }.count == 3)
    }

    /// An unterminated quote must not swallow the rest of the file.
    @Test func aStrayQuoteDoesNotSilenceTheFile() {
        let text = CorpusText(
            source: "let a = \"oops\nguard let b = c else { return }\n", filename: "A.swift")
        #expect(CorpusPatterns.count(#"\bguard\b"#, in: text.code) == 1)
    }
}
