//
//  ProjectCorpusReaderTests.swift
//  MaryPluginTests
//
//  Pins how a writing project on disk becomes an outline — against a project
//  built in a temporary directory, so the rules are exercised without needing
//  anybody's manuscript installed.
//
//  The live half runs as `mary-corpus-probe project`, and it is the half
//  that answers whether a REAL `.scrivx` matches the declaration. What is
//  here is what a real file cannot vary: that the trash is excluded, that a
//  path template cannot leave the project, that nesting comes out as nesting.
//

import Foundation
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class ProjectCorpusReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-\(UUID().uuidString).proj")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var structure: PluginCorpusStructureSchema {
        .init(
            discovery: .directoryExtension,
            projectExtension: "proj",
            manifest: .init(
                kind: .xmlManifest,
                pathTemplate: "{name}.manifest",
                rootElement: "Binder",
                itemElement: "BinderItem",
                idAttribute: "UUID",
                titleElement: "Title",
                childrenElement: "Children",
                typeAttribute: "Type",
                containerTypes: ["Folder", "DraftFolder"],
                draftType: "DraftFolder",
                trashType: "TrashFolder"),
            parts: [
                .init(name: "text", pathTemplate: "Files/{id}/content.txt", format: .plainText),
            ])
    }

    private func writeManifest(_ xml: String) throws {
        let name = root.deletingPathExtension().lastPathComponent
        try xml.write(
            to: root.appendingPathComponent("\(name).manifest"),
            atomically: true, encoding: .utf8)
    }

    private func writeText(_ text: String, id: String) throws {
        let directory = root.appendingPathComponent("Files/\(id)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try text.write(
            to: directory.appendingPathComponent("content.txt"),
            atomically: true, encoding: .utf8)
    }

    private func outline() throws -> [ProjectCorpusReader.Item] {
        switch ProjectCorpusReader.outline(projectRoot: root, structure: structure) {
        case .success(let items): return items
        case .failure(let failure):
            XCTFail("outline failed: \(failure)")
            return []
        }
    }

    // MARK: - Shape

    func testNestingComesOutAsNesting() throws {
        try writeManifest("""
        <Project><Binder>
          <BinderItem UUID="1" Type="DraftFolder"><Title>Manuscript</Title>
            <Children>
              <BinderItem UUID="2" Type="Folder"><Title>Act One</Title>
                <Children>
                  <BinderItem UUID="3" Type="Text"><Title>Scene</Title></BinderItem>
                </Children>
              </BinderItem>
            </Children>
          </BinderItem>
        </Binder></Project>
        """)
        let items = try outline()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Manuscript")
        XCTAssertTrue(items[0].isContainer)
        XCTAssertEqual(items[0].children.first?.title, "Act One")
        XCTAssertEqual(items[0].children.first?.children.first?.title, "Scene")

        // Depth-first, which is the order the outline reads in.
        XCTAssertEqual(
            items.flatMap(\.flattened).map(\.title),
            ["Manuscript", "Act One", "Scene"])
        XCTAssertEqual(items.flatMap(\.flattened).map(\.depth), [0, 1, 2])
    }

    /// A DOCUMENT AND A CONTAINER ARE DIFFERENT THINGS, decided by the
    /// declared type list rather than by whether children happen to exist —
    /// an empty folder is still a folder, and it is still a legal destination
    /// for a move.
    func testAnEmptyContainerIsStillAContainer() throws {
        try writeManifest("""
        <Project><Binder>
          <BinderItem UUID="1" Type="Folder"><Title>Empty</Title></BinderItem>
          <BinderItem UUID="2" Type="Text"><Title>Note</Title></BinderItem>
        </Binder></Project>
        """)
        let items = try outline()
        XCTAssertTrue(items[0].isContainer)
        XCTAssertFalse(items[1].isContainer)
    }

    // MARK: - The trash

    /// THE TRASH IS EXCLUDED, ALWAYS AND WITHOUT A FLAG. A deleted chapter is
    /// not part of the work: counting it in a progress report or offering it
    /// as a destination are both wrong, and there is no request for which
    /// including it is the right answer.
    func testTheTrashAndEverythingUnderItIsExcluded() throws {
        try writeManifest("""
        <Project><Binder>
          <BinderItem UUID="1" Type="Text"><Title>Kept</Title></BinderItem>
          <BinderItem UUID="2" Type="TrashFolder"><Title>Trash</Title>
            <Children>
              <BinderItem UUID="3" Type="Text"><Title>Deleted Chapter</Title></BinderItem>
            </Children>
          </BinderItem>
        </Binder></Project>
        """)
        let titles = try outline().flatMap(\.flattened).map(\.title)
        XCTAssertEqual(titles, ["Kept"])
        // Not merely the folder — the chapter inside it must not survive as
        // an orphan either.
        XCTAssertFalse(titles.contains("Deleted Chapter"))
    }

    // MARK: - Text

    func testTextIsReadThroughTheDeclaredPart() throws {
        try writeManifest("""
        <Project><Binder>
          <BinderItem UUID="abc" Type="Text"><Title>Scene</Title></BinderItem>
        </Binder></Project>
        """)
        try writeText("the comet fell", id: "abc")
        switch ProjectCorpusReader.text(
            itemID: "abc", projectRoot: root, structure: structure) {
        case .success(let text): XCTAssertEqual(text, "the comet fell")
        case .failure(let failure): XCTFail("expected text, got \(failure)")
        }
    }

    /// AN ITEM WITH NO FILE YET IS NOT AN ERROR IN THE PROJECT. A container,
    /// or a document created and not yet written into, simply has no text —
    /// and the sentence for that is different from "I couldn't read it".
    func testAnItemWithNoFileReportsNoTextRatherThanFailing() throws {
        try writeManifest("""
        <Project><Binder>
          <BinderItem UUID="empty" Type="Text"><Title>Blank</Title></BinderItem>
        </Binder></Project>
        """)
        switch ProjectCorpusReader.text(
            itemID: "empty", projectRoot: root, structure: structure) {
        case .success: XCTFail("expected no text")
        case .failure(let failure): XCTAssertEqual(failure, .noText("empty"))
        }
    }

    // MARK: - Paths

    /// A DECLARED TEMPLATE IS DATA, AND DATA THAT COMPOSES A PATH CAN ESCAPE
    /// ONE. The id comes out of a manifest this code did not write, so a
    /// resolved path that leaves the project is refused rather than read.
    func testAPathThatLeavesTheProjectIsRefused() {
        XCTAssertNil(ProjectCorpusReader.resolved("../../etc/passwd", under: root))
        XCTAssertNil(ProjectCorpusReader.resolved("/etc/passwd", under: root))
        XCTAssertNil(ProjectCorpusReader.resolved("Files/../../escape", under: root))
        XCTAssertNil(ProjectCorpusReader.resolved("", under: root))
    }

    func testAPathInsideTheProjectResolves() {
        XCTAssertNotNil(ProjectCorpusReader.resolved("Files/abc/content.txt", under: root))
        // Traversal that stays inside is fine — it is the leaving that is not.
        XCTAssertNotNil(ProjectCorpusReader.resolved("Files/../Files/a", under: root))
    }

    /// An id carrying traversal reaches the same guard, which is the case
    /// that matters: the template is the author's and the id is the file's.
    func testAnIdCarryingTraversalIsRefused() throws {
        try writeManifest("<Project><Binder></Binder></Project>")
        switch ProjectCorpusReader.text(
            itemID: "../../..", projectRoot: root, structure: structure) {
        case .success: XCTFail("a traversing id must not read")
        case .failure(let failure):
            guard case .pathEscapesProject = failure else {
                return XCTFail("expected an escape refusal, got \(failure)")
            }
        }
    }

    // MARK: - Absence

    func testAMissingManifestSaysWhichFileWasMissing() {
        switch ProjectCorpusReader.outline(projectRoot: root, structure: structure) {
        case .success: XCTFail("expected a missing manifest")
        case .failure(let failure):
            guard case .noManifest(let path) = failure else {
                return XCTFail("expected noManifest, got \(failure)")
            }
            XCTAssertTrue(path.hasSuffix(".manifest"))
        }
    }

    // MARK: - fileSystemTree — the directory IS the outline (xcode.mary)

    /// A SECOND STRUCTURE, for the family the header describes: the tree
    /// itself is the outline, an item's id is its path relative to the root,
    /// and there is no manifest to read.
    private var treeStructure: PluginCorpusStructureSchema {
        .init(
            discovery: .manifestPresence,
            manifest: .init(kind: .fileSystemTree),
            parts: [.init(name: "text", pathTemplate: "{id}", format: .plainText)])
    }

    private func write(_ text: String, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// THE PLAIN CASE: no exclude, no include, everything on disk is the
    /// outline — an item's id is its project-relative path.
    func testFileSystemTreeWithNoFilteringShowsEveryFile() throws {
        try write("struct A {}", at: "Sources/A.swift")
        try write("# notes", at: "README.md")
        let titles = try outlineItems(structure: treeStructure).flatMap(\.flattened)
            .map(\.title).sorted()
        XCTAssertEqual(titles, ["A", "README", "Sources"])
    }

    /// ⚠️ THE BUG A LIVE DISPATCH FOUND: an unfiltered walk over a real
    /// checkout reads `.build`/`.git`/`DerivedData` right along with the
    /// source — thousands of files that say nothing about the project's own
    /// shape, and slow enough to matter. `excludeNames` prunes a matched
    /// directory without recursing into it at all.
    func testFileSystemTreeExcludesDeclaredDirectoryNamesEntirely() throws {
        try write("struct A {}", at: "Sources/A.swift")
        try write("// generated", at: ".build/Generated.swift")
        try write("ref: refs/heads/main", at: ".git/HEAD")
        let flat = try outlineItems(
            structure: treeStructure, excludeNames: [".build", ".git"]
        ).flatMap(\.flattened)
        XCTAssertFalse(flat.contains { $0.title == ".build" })
        XCTAssertFalse(flat.contains { $0.title == "Generated" })
        XCTAssertFalse(flat.contains { $0.title == ".git" })
        XCTAssertTrue(flat.contains { $0.title == "A" })
    }

    /// A FILE OUTSIDE THE DECLARED NOTATION is not part of the outline
    /// either — the corpus's own `include`, the same field the passive style
    /// crawl reads, scopes what a code corpus's outline shows to its one
    /// notation.
    func testFileSystemTreeOnlyIncludesDeclaredExtensions() throws {
        try write("struct A {}", at: "A.swift")
        try write("# notes", at: "NOTES.md")
        let titles = try outlineItems(structure: treeStructure, includeExtensions: ["swift"])
            .flatMap(\.flattened).map(\.title)
        XCTAssertEqual(titles, ["A"])
    }

    /// A FOLDER LEFT EMPTY BY FILTERING drops out of the outline too — it
    /// holds nothing this corpus reads, and a container with nothing inside
    /// is worse than not showing it at all.
    func testFileSystemTreeDropsAFolderEmptiedByFiltering() throws {
        try write("# notes", at: "Docs/NOTES.md")
        try write("struct A {}", at: "Sources/A.swift")
        let titles = try outlineItems(structure: treeStructure, includeExtensions: ["swift"])
            .flatMap(\.flattened).map(\.title)
        XCTAssertEqual(titles.sorted(), ["A", "Sources"])
        XCTAssertFalse(titles.contains("Docs"))
    }

    /// THE ID IS THE RELATIVE PATH, and reading through the declared part's
    /// `{id}` template is the join that makes `search_corpus`/
    /// `read_corpus_document` work for this family with no manifest at all.
    func testFileSystemTreeItemIDIsItsRelativePathAndReadsThroughIt() throws {
        try write("struct A {}", at: "Sources/Deep/A.swift")
        let items = try outlineItems(structure: treeStructure).flatMap(\.flattened)
        let file = try XCTUnwrap(items.first { $0.title == "A" })
        XCTAssertEqual(file.id, "Sources/Deep/A.swift")
        switch ProjectCorpusReader.text(
            itemID: file.id, projectRoot: root, structure: treeStructure) {
        case .success(let text): XCTAssertEqual(text, "struct A {}")
        case .failure(let failure): XCTFail("expected text, got \(failure)")
        }
    }

    private func outlineItems(
        structure: PluginCorpusStructureSchema,
        excludeNames: [String] = [], includeExtensions: [String] = []
    ) throws -> [ProjectCorpusReader.Item] {
        switch ProjectCorpusReader.outline(
            projectRoot: root, structure: structure,
            excludeNames: excludeNames, includeExtensions: includeExtensions) {
        case .success(let items): return items
        case .failure(let failure):
            XCTFail("outline failed: \(failure)")
            return []
        }
    }
}
