//
//  CorpusObserverTests.swift
//  MaryPluginTests
//
//  RESOLVING WHAT THE USER SETTLED ON, from what the accessibility tree
//  actually gives — which was measured, not assumed, and was not what the plan
//  expected. `AXDocument` on the workspace window is the PROJECT ROOT; the
//  active file appears only in the window title as `Project — Name`.
//
//  So resolution is root-from-AX plus name-from-title, and a NAME IS NOT A
//  PATH. Everything below is about the gap between those two: two files can
//  share a basename, and the predecessor that guessed between them sent an
//  edit into the wrong repository. Ambiguity resolves to nothing.
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct CorpusObserverTests {

    private let corpus = PluginCorpusSchema(
        include: ["swift"],
        exclude: [".build"],
        notation: "swift",
        relations: .init(declarations: [#"\bstruct\s+([A-Za-z_]\w*)"#]))

    private func project(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-observer-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - The title

    /// The measured format, from a real workspace: `Mary — xcode`.
    @Test func theActiveNameIsTheTitlesLastSegment() {
        #expect(CorpusObserver.activeName(inTitle: "Mary — xcode") == "xcode")
        #expect(CorpusObserver.activeName(inTitle: "Mary — ContentView.swift")
                == "ContentView.swift")
    }

    /// A workspace window with no file open carries no separator. That is an
    /// ordinary state — a welcome window, a settings tab — and not an error.
    @Test func aTitleWithoutAFileResolvesToNothing() {
        #expect(CorpusObserver.activeName(inTitle: "Welcome to Xcode") == nil)
        #expect(CorpusObserver.activeName(inTitle: "Mary — ") == nil)
    }

    // MARK: - Name to path

    @Test func anUnambiguousNameResolves() throws {
        let root = try project([
            "Sources/Parser.swift": "struct Parser {}",
            "Sources/Other.swift": "struct Other {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusObserver.resolve(name: "Parser.swift", root: root.path, corpus: corpus)
                == "Sources/Parser.swift")
    }

    /// The title may omit the extension depending on display settings, so both
    /// spellings resolve.
    @Test func aNameWithoutItsExtensionResolves() throws {
        let root = try project(["Sources/Parser.swift": "struct Parser {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusObserver.resolve(name: "Parser", root: root.path, corpus: corpus)
                == "Sources/Parser.swift")
    }

    /// THE INHERITED DOCTRINE, AND THE POINT OF THIS FILE. Two files sharing a
    /// basename is not a puzzle to solve with a heuristic — it is a question
    /// with no answer, and the predecessor that picked one sent an edit into
    /// the wrong repository.
    @Test func anAmbiguousNameResolvesToNothing() throws {
        let root = try project([
            "AppA/Parser.swift": "struct ParserA {}",
            "AppB/Parser.swift": "struct ParserB {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusObserver.resolve(name: "Parser.swift", root: root.path, corpus: corpus)
                == nil)
    }

    /// A name the corpus does not claim is nothing to crawl. Settling on a
    /// package manifest or a settings tab must not produce a unit.
    @Test func aNameThisCorpusDoesNotClaimResolvesToNothing() throws {
        let root = try project([
            "Sources/Parser.swift": "struct Parser {}",
            "README.md": "# hello",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CorpusObserver.resolve(name: "README.md", root: root.path, corpus: corpus) == nil)
        #expect(CorpusObserver.resolve(name: "Nothing.swift", root: root.path, corpus: corpus) == nil)
    }

    // MARK: - The fresh-edit gate

    /// A file just written is this session's work and may teach style.
    @Test func aJustWrittenFileIsAFreshEdit() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("A.swift").path
        #expect(CorpusObserver.isFreshEdit(path, at: Date()))
    }

    /// A checkout, or another tool's work. Indexed for structure, but reading
    /// a colleague's branch must never file the colleague's habits as yours.
    @Test func anOldWriteIsNotAFreshEdit() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("A.swift").path
        let old = Date().addingTimeInterval(-CorpusObserver.freshEditWindow - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        #expect(!CorpusObserver.isFreshEdit(path, at: Date()))
    }

    @Test func aMissingFileIsNotAFreshEdit() {
        #expect(!CorpusObserver.isFreshEdit("/nowhere/at/all.swift", at: Date()))
    }

    // MARK: - The root

    /// A window showing a loose file gives that file; its project is the
    /// folder holding it.
    @Test func aLooseFilesProjectIsItsFolder() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercised through the same normalisation the AX read uses.
        let asFile = root.appendingPathComponent("A.swift").path
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: asFile, isDirectory: &isDirectory)
        #expect(!isDirectory.boolValue)
    }

    // MARK: - Climbing to the project

    /// ⚠️ THE MEASUREMENT THAT MADE THIS NECESSARY: an editor's `AXDocument`
    /// is the ACTIVE FILE, not the workspace, and no window attribute carries
    /// the workspace at all. Taking the file's own folder as the project
    /// scoped a live crawl to FIVE files in one subdirectory when the project
    /// held 746 — a corpus confidently learning "the project's style" from
    /// four neighbours.
    @Test func theRootIsTheNearestAncestorHoldingAMarker() throws {
        let root = try project([
            "Package.swift": "// package",
            "Sources/Deep/Nested/A.swift": "struct A {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Sources/Deep/Nested").path
        #expect(
            CorpusObserver.projectRoot(containing: nested, markers: ["Package.swift"])
                == root.standardizedFileURL.path)
    }

    /// A dotted marker matches as a SUFFIX, which is the whole of how a
    /// project bundle is recognised — the root holds `Thing.xcodeproj`, and no
    /// package can know the name in front of the dot.
    @Test func aDottedMarkerMatchesTheBundleThatEndsWithIt() throws {
        let root = try project([
            "Thing.xcodeproj/project.pbxproj": "// project",
            "Sources/A.swift": "struct A {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            CorpusObserver.projectRoot(
                containing: root.appendingPathComponent("Sources").path,
                markers: [".xcodeproj"]) == root.standardizedFileURL.path)
    }

    /// THE NEAREST ANCESTOR, not the outermost: a package inside a checkout
    /// is its own project, and learning style across the whole monorepo would
    /// mix one author's conventions with another's.
    @Test func theNearestMarkerWinsOverAFurtherOne() throws {
        let root = try project([
            ".git/HEAD": "ref: refs/heads/main",
            "Inner/Package.swift": "// package",
            "Inner/Sources/A.swift": "struct A {}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            CorpusObserver.projectRoot(
                containing: root.appendingPathComponent("Inner/Sources").path,
                markers: ["Package.swift", ".git"])
                == root.appendingPathComponent("Inner").standardizedFileURL.path)
    }

    /// NOT FOUND IS NOTHING TO CRAWL, not a guess. A file opened from a
    /// download or another checkout belongs to no project this corpus
    /// describes, and inventing its folder as one is how a style profile
    /// learns from work that is not the user's.
    @Test func aFileInNoProjectHasNoRoot() throws {
        let root = try project(["Loose/A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            CorpusObserver.projectRoot(
                containing: root.appendingPathComponent("Loose").path,
                markers: ["Package.swift"]) == nil)
    }

    /// The climb is bounded because a path is data: a marker that is never
    /// found must stop rather than walk to the root of the disk.
    @Test func theClimbIsBounded() throws {
        let root = try project(["A/B/C/D/E/A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            CorpusObserver.projectRoot(
                containing: root.appendingPathComponent("A/B/C/D/E").path,
                markers: ["Package.swift"], maximumDepth: 2) == nil)
    }

    // MARK: - The cache

    /// The index is rebuilt at most once per lifetime — without which settling
    /// on a file would re-read every unit in the project, seconds of work for
    /// something a person does every few seconds.
    @Test func theIndexIsBuiltOncePerLifetime() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CorpusTypeIndexCache()
        var builds = 0
        let now = Date()
        for _ in 0..<5 {
            _ = cache.index(root: root.path, corpus: corpus, at: now) {
                builds += 1
                return CorpusTypeIndex(root: root.path, files: [])
            }
        }
        #expect(builds == 1)
    }

    @Test func thecacheRebuildsPastItsLifetime() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CorpusTypeIndexCache()
        var builds = 0
        let start = Date()
        for offset in [0.0, CorpusTypeIndexCache.lifetime + 1] {
            _ = cache.index(
                root: root.path, corpus: corpus, at: start.addingTimeInterval(offset)
            ) {
                builds += 1
                return CorpusTypeIndex(root: root.path, files: [])
            }
        }
        #expect(builds == 2)
    }

    @Test func forgettingAProjectRebuildsIt() throws {
        let root = try project(["A.swift": "struct A {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CorpusTypeIndexCache()
        var builds = 0
        let now = Date()
        func build() -> CorpusTypeIndex {
            builds += 1
            return CorpusTypeIndex(root: root.path, files: [])
        }
        _ = cache.index(root: root.path, corpus: corpus, at: now, build: build)
        cache.forget(root: root.path)
        _ = cache.index(root: root.path, corpus: corpus, at: now, build: build)
        #expect(builds == 2)
    }
}
