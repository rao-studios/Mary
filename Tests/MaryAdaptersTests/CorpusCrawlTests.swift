//
//  CorpusCrawlTests.swift
//  MaryAdaptersTests
//
//  THE REACH, ON A REAL TREE.
//
//  The crawl's value is entirely in what it REFUSES to walk. One hop through
//  ordinary references and a second only through ancestry is not a performance
//  compromise — it is the difference between a neighbourhood and half the
//  project. A crawl that returns sixty files is a worse answer than one that
//  returns eight, no matter how much of it is true, so the caps and the
//  asymmetry are the behaviour worth pinning.
//
//  These write actual files into a temporary directory, because the walk reads
//  a filesystem: extension filtering, excluded directories and the size cap
//  are all facts about paths and bytes, and a fixture that mocked them would
//  pin the mock.
//

import Foundation
import MaryAmbient
import MaryFoundation
import Testing
@testable import MaryAdapters

@Suite struct CorpusCrawlTests {

    private let corpus = PluginCorpusSchema(
        include: ["swift"],
        exclude: [".build", "Generated"],
        notation: "swift",
        relations: .init(
            references: [#"\b([A-Z][A-Za-z0-9_]*)\("#],
            ancestry: [#"\bstruct\s+[A-Za-z_]\w*\s*:\s*([A-Za-z_][A-Za-z0-9_,<>\.\s]*)"#],
            declarations: [#"\b(?:struct|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#]))

    /// Builds a throwaway project and hands back its root.
    private func project(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-corpus-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func index(root: URL, corpus: PluginCorpusSchema) -> CorpusTypeIndex {
        let paths = CorpusCrawl.projectFiles(root: root.path, corpus: corpus)
        return CorpusTypeIndex(
            root: root.path,
            files: paths.map { path in
                let read = CorpusCrawl.read(relativePath: path, root: root.path, corpus: corpus)
                return (relativePath: path, declaredNames: read?.declaredNames ?? [])
            })
    }

    private func crawl(
        _ root: URL, from focused: String, corpus: PluginCorpusSchema? = nil
    ) -> [IndexedUnit] {
        let schema = corpus ?? self.corpus
        return CorpusCrawl.crawl(
            focusedPath: root.appendingPathComponent(focused).path,
            root: root.path,
            projectName: "demo",
            corpus: schema,
            index: index(root: root, corpus: schema),
            applicationID: "xcode")
    }

    // MARK: - Which files are units

    @Test func onlyDeclaredExtensionsAreUnits() throws {
        let root = try project([
            "A.swift": "struct A {}",
            "README.md": "# not a unit",
            "data.json": "{}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusCrawl.projectFiles(root: root.path, corpus: corpus) == ["A.swift"])
    }

    /// A walk through build products reads thousands of generated files to
    /// learn nothing about how a person writes.
    @Test func excludedDirectoriesAreNotWalked() throws {
        let root = try project([
            "A.swift": "struct A {}",
            ".build/Junk.swift": "struct Junk {}",
            "Generated/Also.swift": "struct Also {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusCrawl.projectFiles(root: root.path, corpus: corpus) == ["A.swift"])
    }

    @Test func aFilePastTheSizeCapIsNotRead() throws {
        let root = try project(["Big.swift": String(repeating: "// x\n", count: 500)])
        defer { try? FileManager.default.removeItem(at: root) }
        var tight = corpus
        tight.budgets = .init(maximumFiles: 24, maximumEdges: 120, maximumFileBytes: 100)
        #expect(CorpusCrawl.read(relativePath: "Big.swift", root: root.path, corpus: tight) == nil)
    }

    // MARK: - The reach

    @Test func theFocusedFileIsAlwaysTheFirstUnit() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let units = crawl(root, from: "A.swift")
        #expect(units.count == 1)
        #expect(units.first?.relativePath == "A.swift")
        #expect(units.first?.declaredTypes == ["A"])
    }

    @Test func aReferenceIsWorthOneHop() throws {
        let root = try project([
            "A.swift": "struct A { func go() { B() } }",
            "B.swift": "struct B {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Set(crawl(root, from: "A.swift").map(\.relativePath)) == ["A.swift", "B.swift"])
    }

    /// THE ASYMMETRY. A second hop through an ordinary reference would drag in
    /// half the project, so C is not in A's neighbourhood.
    @Test func aReferenceIsNotWorthTwo() throws {
        let root = try project([
            "A.swift": "struct A { func go() { B() } }",
            "B.swift": "struct B { func go() { C() } }",
            "C.swift": "struct C {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let reached = Set(crawl(root, from: "A.swift").map(\.relativePath))
        #expect(reached == ["A.swift", "B.swift"])
        #expect(!reached.contains("C.swift"))
    }

    /// Ancestry IS worth the second hop: a base type or protocol is where the
    /// semantics of a subtype live.
    @Test func ancestryIsWorthTheSecondHop() throws {
        let root = try project([
            "A.swift": "struct A { func go() { B() } }",
            "B.swift": "struct B: Fancy {}",
            "Fancy.swift": "protocol Fancy {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Set(crawl(root, from: "A.swift").map(\.relativePath))
                == ["A.swift", "B.swift", "Fancy.swift"])
    }

    @Test func theFileCapBoundsTheNeighbourhood() throws {
        var files = ["A.swift": "struct A { func go() { B(); C(); D(); E() } }"]
        for name in ["B", "C", "D", "E"] { files["\(name).swift"] = "struct \(name) {}" }
        let root = try project(files)
        defer { try? FileManager.default.removeItem(at: root) }
        var tight = corpus
        tight.budgets = .init(maximumFiles: 3, maximumEdges: 120, maximumFileBytes: 400_000)
        #expect(crawl(root, from: "A.swift", corpus: tight).count == 3)
    }

    // MARK: - Edges

    @Test func ancestryAndReferencesBecomeDistinctEdges() throws {
        let root = try project([
            "A.swift": "struct A: Fancy { func go() { B() } }",
            "B.swift": "struct B {}",
            "Fancy.swift": "protocol Fancy {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let focused = crawl(root, from: "A.swift").first { $0.relativePath == "A.swift" }
        let predicates = Set(focused?.relations.map(\.predicate) ?? [])
        #expect(predicates.contains(.inheritsFrom))
        #expect(predicates.contains(.holds))
    }

    /// A reference resolving to nothing in the project is not an edge — it is
    /// almost always a system type, and pointing at it would say nothing.
    @Test func anUnresolvableReferenceIsNotAnEdge() throws {
        let root = try project(["A.swift": "struct A { func go() { URLSession() } }"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(crawl(root, from: "A.swift").first?.relations.isEmpty == true)
    }

    // MARK: - Clause splitting

    @Test func anInheritanceClauseSplitsIntoItsNames() {
        #expect(CorpusCrawl.names(inClause: "Fancy, Other") == ["Fancy", "Other"])
        // Generic arguments and module qualifiers are not declared names.
        #expect(CorpusCrawl.names(inClause: "Collection<Int>") == ["Collection"])
        #expect(CorpusCrawl.names(inClause: "Swift.Equatable") == ["Equatable"])
    }

    // MARK: - Identity

    /// Units address by PROJECT-RELATIVE path: an absolute one is machine
    /// -local, and the addressing has to survive being carried elsewhere.
    @Test func unitsAddressByRelativePath() throws {
        let root = try project(["Deep/Nested/A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let unit = crawl(root, from: "Deep/Nested/A.swift").first
        #expect(unit?.relativePath == "Deep/Nested/A.swift")
        #expect(unit?.subject.projectIdentity == root.path)
    }

    /// The same bytes hash the same; different bytes do not. This is the value
    /// the whole re-annotation gate turns on.
    @Test func theContentHashFollowsTheContent() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = crawl(root, from: "A.swift").first?.contentHash
        try "struct A { let b = 1 }".write(
            to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        #expect(crawl(root, from: "A.swift").first?.contentHash != first)
    }
}
