//
//  AwarenessTraceTests.swift
//  MaryPluginTests
//
//  WHAT: The unit at the caret, who reaches it, what it reaches, and where
//        the user's words land — over a real tree, with the SHIPPED grammar.
//  OUT:  EnclosingUnit / CorpusTracer / CorpusDeclarationIndex / AwarenessBrief
//  PIN:  The grammar comes out of `Abilities/xcode.mary`, so a regex edited
//        there is felt here rather than in a golden nobody re-reads.
//

import Foundation
import MaryAmbient
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct AwarenessTraceTests {

    // MARK: - The shipped declaration

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryPluginTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    static let shippedSwiftGrammar: PluginCorpusSchema? = {
        let url = repositoryRoot.appendingPathComponent("Abilities/xcode.mary")
        guard let data = try? Data(contentsOf: url),
              let package = try? AbilityPackageCodec.decode(data)
        else { return nil }
        return package.plugin?.corpus
    }()

    private func project(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-awareness-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// A small project that reaches across itself, so a trace has something
    /// true to find.
    private static let reader = """
    import Foundation

    /// Reads a buffer.
    struct BufferReader {
        let path: String

        func read() -> String {
            let text = load(path)
            return trim(text)
        }

        func load(_ path: String) -> String { path }

        func trim(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces)
        }
    }
    """

    private static let caller = """
    import Foundation

    struct Session {
        func open() -> String {
            let reader = BufferReader(path: "/tmp/x")
            return reader.read()
        }

        func reopen() -> String {
            BufferReader(path: "/tmp/y").read()
        }
    }
    """

    private static let bystander = """
    import Foundation

    /// Never mentions the reader. The retry logic lives here.
    struct Retry {
        func attempt() -> Bool { true }
    }
    """

    private func sampleProject() throws -> (root: URL, corpus: PluginCorpusSchema) {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let root = try project([
            "Sources/BufferReader.swift": Self.reader,
            "Sources/Session.swift": Self.caller,
            "Sources/Retry.swift": Self.bystander,
            "Package.swift": "// swift-tools-version: 6.0\n",
        ])
        CorpusTextCache.shared.forget(root: root.path)
        CorpusDeclarationIndexCache.shared.forget(root: root.path)
        return (root, corpus)
    }

    // MARK: - The unit

    /// A WINDOW IS NOT A UNIT. The caret inside a function's body yields the
    /// whole function, brace to brace, not a character window around it.
    @Test func theCaretYieldsTheWholeDeclaration() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let caret = try #require(Self.reader.range(of: "let text = load(path)"))
            .lowerBound
        let offset = Self.reader.distance(from: Self.reader.startIndex, to: caret)
        let unit = try #require(EnclosingUnit.locate(
            in: Self.reader, caret: offset, corpus: corpus))
        #expect(unit.name == "read")
        #expect(unit.kind == "func")
        #expect(unit.body.contains("func read() -> String {"))
        #expect(unit.body.contains("return trim(text)"))
        // Whole: it ends where the declaration ends, not where a budget did.
        #expect(unit.isWhole)
        #expect(!unit.body.contains("func load"), "the NEXT declaration is not this one")
        #expect(unit.chain.contains("struct BufferReader"))
        #expect(unit.scope.contains("→"))
    }

    /// The user's own highlight is marked inside the unit, so a question about
    /// one line inside a long function stays about that line.
    @Test func theHighlightIsMarkedInsideTheUnit() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let range = try #require(Self.reader.range(of: "return trim(text)"))
        let lower = Self.reader.distance(from: Self.reader.startIndex, to: range.lowerBound)
        let upper = Self.reader.distance(from: Self.reader.startIndex, to: range.upperBound)
        let unit = try #require(EnclosingUnit.locate(
            in: Self.reader, caret: lower, corpus: corpus, highlight: lower..<upper))
        #expect(unit.body.contains("[[return trim(text)]]"))
    }

    /// An enormous declaration is truncated and SAYS it was.
    @Test func anEnormousUnitIsTruncatedHonestly() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let filler = (0..<800).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        let source = "struct Big {\n    func huge() {\n\(filler)\n    }\n}\n"
        let caret = source.distance(
            from: source.startIndex,
            to: try #require(source.range(of: "let value400")).lowerBound)
        let unit = try #require(EnclosingUnit.locate(
            in: source, caret: caret, corpus: corpus))
        #expect(!unit.isWhole)
        #expect(unit.body.count <= EnclosingUnit.characterBudget + 64)
    }

    /// A notation with no brace grammar still gets a unit: the declared
    /// pattern says where it starts, indentation says where it ends.
    @Test func aNonSwiftNotationFallsBackToIndentation() throws {
        let corpus = PluginCorpusSchema(
            include: ["py"],
            notation: "python",
            relations: .init(declarations: [#"\bdef\s+([A-Za-z_]\w*)"#]))
        let source = """
        import os

        def first():
            value = 1
            return value

        def second():
            return 2
        """
        let caret = source.distance(
            from: source.startIndex,
            to: try #require(source.range(of: "value = 1")).lowerBound)
        let unit = try #require(EnclosingUnit.locate(
            in: source, caret: caret, corpus: corpus))
        #expect(unit.name == "first")
        #expect(unit.body.contains("return value"))
        #expect(!unit.body.contains("def second"))
    }

    // MARK: - The declaration index

    /// EVERY declaration, not the first — the question tracing asks is the
    /// opposite of the crawl's, and it has to see the rivals.
    @Test func theIndexHoldsEveryDeclarationWithItsLine() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let read = index.declarations(named: "read")
        #expect(read.count == 1)
        #expect(read.first?.relativePath == "Sources/BufferReader.swift")
        #expect(read.first?.header.contains("func read()") == true)
        #expect(index.declares("BufferReader"))
        #expect(!index.declares("URLSession"))
        // The declaration a call site sits inside — approximate by position,
        // exact enough to name.
        let session = index.nearest(in: "Sources/Session.swift", line: 6)
        #expect(session?.name == "open")
    }

    // MARK: - Who reaches this

    @Test func callersNameTheirFileLineAndEnclosingDeclaration() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "read", root: root.path, corpus: corpus,
            excluding: "Sources/BufferReader.swift", declarations: index)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.relativePath == "Sources/Session.swift" })
        #expect(Set(hits.compactMap(\.enclosing)) == ["open", "reopen"])
        #expect(hits.allSatisfy { $0.line > 0 })
        #expect(hits.contains { $0.snippet.contains("reader.read()") })
    }

    /// A type is reached by being mentioned at all — an initializer is a use.
    @Test func aTypeIsReachedByBeingNamed() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "BufferReader", root: root.path, corpus: corpus,
            excluding: "Sources/BufferReader.swift", declarations: index)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.relativePath == "Sources/Session.swift" })
    }

    /// A NAME IN A COMMENT IS NOT A CALLER. The code slice is what is scanned,
    /// which is `CorpusText`'s whole reason for existing.
    @Test func aMentionInACommentIsNotACaller() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let root = try project([
            "Sources/BufferReader.swift": Self.reader,
            "Sources/Note.swift": """
            import Foundation

            // We should call read() here one day.
            struct Note {
                let text = "read()"
            }
            """,
            "Package.swift": "// swift-tools-version: 6.0\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        CorpusTextCache.shared.forget(root: root.path)
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "read", root: root.path, corpus: corpus,
            excluding: "Sources/BufferReader.swift", declarations: index)
        #expect(hits.isEmpty)
    }

    /// A CALLER IN THE SAME FILE IS STILL A CALLER, and often the only one
    /// that matters. Excluding the whole file made a private helper called
    /// twice from six lines above read as "nothing reaches it".
    @Test func aCallerInTheSameFileIsFound() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let root = try project([
            "Sources/Solo.swift": """
            struct Solo {
                func run() -> String {
                    helper()
                }

                func helper() -> String { "x" }
            }
            """,
            "Package.swift": "// swift-tools-version: 6.0\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        CorpusTextCache.shared.forget(root: root.path)
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "helper", root: root.path, corpus: corpus, declarations: index)
        #expect(hits.count == 1)
        #expect(hits.first?.relativePath == "Sources/Solo.swift")
        #expect(hits.first?.enclosing == "run")
    }

    /// The declaration is not one of its own callers.
    @Test func aDeclarationDoesNotReachItself() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "read", root: root.path, corpus: corpus, declarations: index)
        #expect(!hits.contains { $0.relativePath == "Sources/BufferReader.swift" })
    }

    // MARK: - What this reaches

    /// Callees are resolved to WHERE THEY LIVE, and only the project's own
    /// declarations survive: a trace through the standard library is noise.
    @Test func calleesResolveToTheProjectsOwnDeclarations() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let caret = Self.reader.distance(
            from: Self.reader.startIndex,
            to: try #require(Self.reader.range(of: "let text = load(path)")).lowerBound)
        let unit = try #require(EnclosingUnit.locate(
            in: Self.reader, caret: caret, corpus: corpus))
        let hits = CorpusTracer.callees(
            in: unit.body, own: unit.name, corpus: corpus, declarations: index)
        let names = Set(hits.compactMap(\.enclosing))
        #expect(names.contains("load"))
        #expect(names.contains("trim"))
        #expect(!names.contains("trimmingCharacters"), "not the project's to claim")
        #expect(hits.allSatisfy { $0.relativePath == "Sources/BufferReader.swift" })
    }

    // MARK: - Where the words land

    @Test func searchReturnsRealLinesWithTheirNumbers() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.search(
            for: "retry", root: root.path, corpus: corpus, declarations: index)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.relativePath == "Sources/Retry.swift" })
        #expect(hits.allSatisfy { $0.line > 0 })
        #expect(hits.contains { $0.snippet.lowercased().contains("retry") })
    }

    /// The words worth searching for are the ones carrying the subject.
    @Test func contentWordsDropWhatEnglishDoesBetweenThem() {
        let words = CorpusTracer.contentWords(of: "what do you think about this retry logic")
        #expect(words.contains("retry"))
        #expect(words.contains("logic"))
        #expect(!words.contains("this"))
        #expect(!words.contains("think"))
        #expect(!words.contains("about"))
    }

    /// CAPS ARE THE FEATURE. Eight bearings a person can hold beat forty they
    /// cannot, and no single file may be the whole answer.
    @Test func capsBoundEveryTrace() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        var files: [String: String] = ["Package.swift": "// swift-tools-version: 6.0\n"]
        files["Sources/Target.swift"] = "struct Target {\n    func ping() {}\n}\n"
        for index in 0..<20 {
            files["Sources/Caller\(index).swift"] = """
            struct Caller\(index) {
                func a() { ping() }
                func b() { ping() }
                func c() { ping() }
                func d() { ping() }
            }
            """
        }
        let root = try project(files)
        defer { try? FileManager.default.removeItem(at: root) }
        CorpusTextCache.shared.forget(root: root.path)
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        let hits = CorpusTracer.callers(
            of: "ping", root: root.path, corpus: corpus,
            excluding: "Sources/Target.swift", declarations: index)
        #expect(hits.count == CorpusTracer.hitLimit)
        let perFile = Dictionary(grouping: hits, by: \.relativePath)
        #expect(perFile.values.allSatisfy { $0.count <= CorpusTracer.perFileLimit })
    }

    // MARK: - The brief

    /// A unit line ALONE is a receipt, not evidence — and a receipt served as
    /// sight is how a question about code gets answered having read none.
    @Test func aBriefWithNoBearingsSaysNothing() throws {
        let unit = EnclosingUnit(
            name: "read", kind: "func", chain: ["struct BufferReader", "func read"],
            startLine: 7, endLine: 10, body: "func read() {}", isWhole: true)
        #expect(AwarenessBrief.surroundings(
            unit: unit, fileName: "BufferReader.swift",
            callers: [], callees: [], matches: [], query: nil) == nil)
    }

    @Test func aBriefNamesTheFileAndLineOfEveryBearing() throws {
        let unit = EnclosingUnit(
            name: "read", kind: "func", chain: ["struct BufferReader", "func read"],
            startLine: 7, endLine: 10, body: "func read() {}", isWhole: true)
        let hit = TraceHit(
            relativePath: "Sources/Session.swift", line: 6,
            snippet: "return reader.read()", enclosing: "open")
        let brief = try #require(AwarenessBrief.surroundings(
            unit: unit, fileName: "BufferReader.swift",
            callers: [hit], callees: [], matches: [], query: nil))
        #expect(brief.contains("Sources/Session.swift:6"))
        #expect(brief.contains("open"))
        #expect(brief.contains("Reached from:"))
        #expect(brief.count <= AwarenessBrief.surroundingsBudget)
    }

    /// The standing brief carries bearings, never the body — the caret window
    /// already holds the text, and paying for it twice is what a budget is.
    @Test func theStandingBriefCarriesBearingsNotTheBody() {
        let unit = EnclosingUnit(
            name: "read", kind: "func", chain: ["struct BufferReader", "func read"],
            startLine: 7, endLine: 10,
            body: "func read() -> String { UNIQUEBODYTOKEN }", isWhole: true)
        let brief = AwarenessBrief.standing(
            unit: unit, fileName: "BufferReader.swift",
            callers: [TraceHit(
                relativePath: "Sources/Session.swift", line: 6,
                snippet: "return reader.read()", enclosing: "open")],
            callees: [])
        #expect(!brief.contains("UNIQUEBODYTOKEN"))
        #expect(brief.contains("func read"))
        #expect(brief.contains("Sources/Session.swift:6"))
        #expect(brief.count <= AwarenessBrief.standingBudget)
    }

    /// Nothing reaching it is a REAL answer, said plainly.
    @Test func nothingReachingItIsSaidPlainly() {
        let unit = EnclosingUnit(
            name: "read", kind: "func", chain: [], startLine: 1, endLine: 2,
            body: "func read() {}", isWhole: true)
        let brief = AwarenessBrief.standing(
            unit: unit, fileName: "BufferReader.swift", callers: [], callees: [])
        #expect(brief.contains("Nothing else in the project reaches it"))
    }

    // MARK: - The line they are standing on

    /// THE COMMONEST CARET THERE IS: on the signature line itself, because
    /// they just wrote it or just clicked it. A brace walk reports only what
    /// is already OPEN there — the enclosing type — and handed back six
    /// thousand characters of class instead of the function in front of them.
    /// Measured against this repository, not imagined.
    @Test func aCaretOnTheSignatureLineYieldsThatDeclaration() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let caret = Self.reader.distance(
            from: Self.reader.startIndex,
            to: try #require(Self.reader.range(of: "func read() -> String {")).lowerBound)
        let unit = try #require(EnclosingUnit.locate(
            in: Self.reader, caret: caret, corpus: corpus))
        #expect(unit.name == "read")
        #expect(unit.kind == "func")
        #expect(unit.isWhole)
        #expect(!unit.body.contains("func load"), "the function, not the type around it")
    }

    /// A caret in the type's own body — not on any declaration line — still
    /// reports the type. The exception above must not swallow the rule.
    @Test func aCaretBetweenDeclarationsStillReportsTheEnclosingType() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let caret = Self.reader.distance(
            from: Self.reader.startIndex,
            to: try #require(Self.reader.range(of: "let path: String")).lowerBound)
        let unit = try #require(EnclosingUnit.locate(
            in: Self.reader, caret: caret, corpus: corpus))
        #expect(unit.name == "BufferReader")
        #expect(unit.kind == "struct")
    }

    // MARK: - Whose declaration it is

    /// A NAMESAKE ELSEWHERE IS NOT THIS ONE. Two files declaring `helper`
    /// resolved to whichever sorted first, so a trace of one file's body
    /// pointed confidently into another file — the exact species of wrong
    /// answer a bearing exists to prevent.
    @Test func aCalleeResolvesToItsOwnFileWhenNamesCollide() throws {
        let corpus = try #require(Self.shippedSwiftGrammar)
        let root = try project([
            "Sources/Alpha.swift": """
            struct Alpha {
                func helper() -> Int { 1 }
                func run() -> Int { helper() }
            }
            """,
            "Sources/Beta.swift": """
            struct Beta {
                func helper() -> Int { 2 }
            }
            """,
            "Package.swift": "// swift-tools-version: 6.0\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        CorpusTextCache.shared.forget(root: root.path)
        let index = CorpusDeclarationIndexCache.build(root: root.path, corpus: corpus)
        #expect(index.declarations(named: "helper").count == 2, "precondition: they collide")
        let hits = CorpusTracer.callees(
            in: "func run() -> Int { helper() }", own: "run", corpus: corpus,
            declarations: index, in: "Sources/Alpha.swift")
        #expect(hits.contains {
            $0.enclosing == "helper" && $0.relativePath == "Sources/Alpha.swift"
        })
        #expect(!hits.contains { $0.relativePath == "Sources/Beta.swift" })
    }

    // MARK: - A walk that ran out of time

    /// A TURN CANNOT SPEND SECONDS. Past its deadline the walk stops, says it
    /// is partial, and is NOT cached — so the observer's own unbounded walk
    /// completes it rather than a truncated one being remembered as the truth.
    @Test func aBoundedWalkStopsAndSaysSo() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = CorpusDeclarationIndexCache.build(
            root: root.path, corpus: corpus, within: 0)
        #expect(!partial.isComplete)

        let cache = CorpusDeclarationIndexCache()
        _ = cache.index(root: root.path, corpus: corpus, within: 0)
        // Not remembered: the next build is free to finish the job.
        let whole = cache.index(root: root.path, corpus: corpus)
        #expect(whole.isComplete)
        #expect(whole.declares("BufferReader"))
    }

    /// AND ITS SILENCE IS NOT AN ANSWER. "Nothing reaches this" is a claim a
    /// half-read project has not earned.
    @Test func aPartialWalkNeverClaimsNothingReachesIt() {
        let unit = EnclosingUnit(
            name: "read", kind: "func", chain: [], startLine: 1, endLine: 2,
            body: "func read() {}", isWhole: true)
        let partial = AwarenessBrief.standing(
            unit: unit, fileName: "BufferReader.swift",
            callers: [], callees: [], complete: false)
        #expect(!partial.contains("Nothing else in the project reaches it"))
        let whole = AwarenessBrief.standing(
            unit: unit, fileName: "BufferReader.swift",
            callers: [], callees: [], complete: true)
        #expect(whole.contains("Nothing else in the project reaches it"))
    }

    // MARK: - The cache

    /// A body is never served stale: the file's own modification date is the
    /// gate, not a clock.
    @Test func aChangedFileIsReReadImmediately() throws {
        let (root, corpus) = try sampleProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CorpusTextCache()
        let first = try #require(cache.text(
            relativePath: "Sources/Retry.swift", root: root.path, corpus: corpus))
        #expect(first.source.contains("func attempt"))

        try "struct Retry {\n    func rewritten() -> Bool { false }\n}\n"
            .write(
                to: root.appendingPathComponent("Sources/Retry.swift"),
                atomically: true, encoding: .utf8)
        let second = try #require(cache.text(
            relativePath: "Sources/Retry.swift", root: root.path, corpus: corpus))
        #expect(second.source.contains("func rewritten"))
        #expect(!second.source.contains("func attempt"))
    }
}
