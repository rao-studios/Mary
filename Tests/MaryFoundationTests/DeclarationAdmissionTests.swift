//
//  DeclarationAdmissionTests.swift
//  MaryFoundationTests
//
//  WHAT: Declaration replaces an app-specific observer (code / prose / corpus).
//  OUT:  PluginValidator + codec — happy path and the refusals that would fail mid-document
//  PIN:  Unknown keys refused; a pattern that cannot compile never silently no-ops
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct DeclarationAdmissionTests {

    private func codeCodes(_ surface: PluginCodeSurfaceSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCodeSurface(surface, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func proseCodes(_ surface: PluginProseSurfaceSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateProseSurface(surface, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func corpusCodes(_ corpus: PluginCorpusSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCorpus(corpus, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func structureCodes(_ structure: PluginCorpusStructureSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCorpusStructure(structure, path: "plugin.corpus.structure") {
            code, _, _ in collected.append(code)
        }
        return collected
    }

    private func validCorpus() -> PluginCorpusSchema {
        PluginCorpusSchema(
            include: ["swift"],
            notation: "swift",
            relations: .init(
                references: [#"\b([A-Z]\w*)\("#],
                declarations: [#"\bstruct\s+(\w+)"#]))
    }

    private func validStructure(
        manifest: PluginCorpusManifest? = nil
    ) -> PluginCorpusStructureSchema {
        .init(
            discovery: .directoryExtension,
            projectExtension: "scriv",
            openState: [.lockFile, .runningApplication],
            lockFilePath: "user.lock",
            manifest: manifest ?? .init(
                kind: .xmlManifest,
                pathTemplate: "{name}.scrivx",
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
                .init(name: "text", pathTemplate: "Files/Data/{id}/content.rtf", format: .rtf),
            ],
            documentURLTemplate: "x-scrivener-item:///{project}?id={id}",
            handlePrefix: "D",
            ceremonies: [
                .init(act: .addItem, menuPath: ["Project", "New Text"]),
            ])
    }

    @Test func aWellFormedCodeSurfaceIsAdmitted() {
        #expect(codeCodes(PackageFixtures.codeSurface).isEmpty)
    }

    @Test func aCodeSurfaceWithNoEditorRoleIsRefused() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = []
        #expect(codeCodes(surface).contains("missing-code-editor-role"))
    }

    @Test func aCodeSurfaceUnknownKeyIsRefused() {
        let json = Data(#"{ "handlePrefix": "C", "grammar": "prose" }"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginCodeSurfaceSchema.self, from: json)
        }
    }

    @Test func aWellFormedProseSurfaceIsAdmitted() {
        #expect(proseCodes(PackageFixtures.proseSurface).isEmpty)
    }

    @Test func aChordWithoutAModifierIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.chords = [.newDocument: .init(key: .n, modifiers: [])]
        #expect(proseCodes(surface).contains("unmodified-prose-chord"))
    }

    @Test func aWellFormedCorpusAdmitsSilently() {
        #expect(corpusCodes(validCorpus()).isEmpty)
    }

    @Test func aPatternThatCannotCompileIsRefused() {
        let corpus = PluginCorpusSchema(
            include: ["swift"], notation: "swift",
            relations: .init(declarations: ["([A-Z"]))
        #expect(corpusCodes(corpus).contains("corpus-pattern-invalid"))
    }

    @Test func aMeasuredStructureAdmitsSilently() {
        #expect(structureCodes(validStructure()).isEmpty)
    }

    @Test func anXMLManifestMissingItsElementNamesIsRefused() {
        #expect(structureCodes(validStructure(manifest: .init(kind: .xmlManifest)))
            .contains("corpus-manifest-incomplete"))
    }

    @Test func aStructureRoundTripsToTheSameBytes() throws {
        let corpus = PluginCorpusSchema(
            include: ["rtf"], notation: "prose", structure: validStructure())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(corpus)
        let decoded = try JSONDecoder().decode(PluginCorpusSchema.self, from: data)
        #expect(decoded == corpus)
        #expect(try encoder.encode(decoded) == data)
    }
}
