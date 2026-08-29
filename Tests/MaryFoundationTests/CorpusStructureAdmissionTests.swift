//
//  CorpusStructureAdmissionTests.swift
//  MaryFoundationTests
//
//  A PROJECT'S SHAPE ON DISK, CHECKED BEFORE ANYBODY ASKS FOR IT.
//
//  The `structure` sub-block is a claim about a directory nobody has looked in
//  yet: that a manifest is at this path, that items are this element with the
//  id in this attribute, that "Move To" is where this application keeps it.
//  Every field can be individually well-formed JSON while the whole says
//  nothing a reader can act on — an `xmlManifest` with no element names
//  decodes, admits, and then fails at the moment a user asks for their
//  outline. That is the worst moment to find out, because by then they have
//  asked for something.
//
//  WHAT IS DELIBERATELY NOT CHECKED HERE is anything about the disk. Whether
//  the project exists, whether the manifest is where the template says, and
//  whether "TrashFolder" is really Scrivener's spelling are facts about a real
//  file, and they belong to `mary-corpus-probe project`. Admission checks only
//  that the declaration COULD be satisfied.
//
//  ROUND-TRIPPING IS PINNED for the usual reason: the package digest is taken
//  over these bytes, so a `structure` that encodes as `null` when absent would
//  change the digest of every package that does not declare one — xcode.mary
//  included.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct CorpusStructureAdmissionTests {

    // MARK: - Helpers

    private func codes(_ structure: PluginCorpusStructureSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCorpusStructure(structure, path: "plugin.corpus.structure") {
            code, _, _ in collected.append(code)
        }
        return collected
    }

    /// The measured Scrivener-shaped declaration — the baseline each test
    /// perturbs in exactly one way.
    private func valid(
        manifest: PluginCorpusManifest? = nil,
        parts: [PluginCorpusPart]? = nil,
        openState: [PluginCorpusOpenState] = [.lockFile, .runningApplication],
        lockFilePath: String? = "user.lock",
        documentURLTemplate: String? = "x-scrivener-item:///{project}?id={id}",
        handlePrefix: String? = "D",
        ceremonies: [PluginCorpusCeremony] = [
            .init(act: .addItem, menuPath: ["Project", "New Text"]),
            .init(act: .moveToContainer, menuPath: ["Documents", "Move To"],
                  completedByContainer: true),
        ]
    ) -> PluginCorpusStructureSchema {
        .init(
            discovery: .directoryExtension,
            projectExtension: "scriv",
            openState: openState,
            lockFilePath: lockFilePath,
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
            parts: parts ?? [
                .init(name: "text", pathTemplate: "Files/Data/{id}/content.rtf", format: .rtf),
            ],
            documentURLTemplate: documentURLTemplate,
            handlePrefix: handlePrefix,
            ceremonies: ceremonies)
    }

    // MARK: - The baseline

    @Test func theMeasuredDeclarationAdmitsSilently() {
        #expect(codes(valid()).isEmpty)
    }

    /// A FOLDER OF MARKDOWN IS THE OTHER MEMBER OF THE FAMILY, and it declares
    /// almost nothing — the tree is the outline and an item's id is its path.
    @Test func aFileSystemTreeProjectAdmitsWithNoElementNames() {
        #expect(codes(.init(
            discovery: .manifestPresence,
            openState: [.alwaysOpen],
            manifest: .init(kind: .fileSystemTree),
            parts: [.init(name: "text", pathTemplate: "{id}", format: .markdown)])).isEmpty)
    }

    // MARK: - The manifest

    /// THE ID IS THE JOIN between the outline and the text on disk. An outline
    /// parsed without one reads perfectly and can open nothing — which is why
    /// the probe counts ids at all.
    @Test func anXMLManifestMissingItsElementNamesIsRefused() {
        let codes = codes(valid(manifest: .init(kind: .xmlManifest)))
        #expect(codes.filter { $0 == "corpus-manifest-incomplete" }.count == 4)
    }

    @Test func anXMLManifestMissingOnlyTheIdIsStillRefused() {
        #expect(codes(valid(manifest: .init(
            kind: .xmlManifest,
            pathTemplate: "{name}.scrivx",
            rootElement: "Binder",
            itemElement: "BinderItem"))).contains("corpus-manifest-incomplete"))
    }

    /// A DECLARATION THAT LOOKS LIKE IT IS WORKING AND IS NOT: element names
    /// under a `fileSystemTree` are never read, so the author believes they
    /// have described an outline and has described nothing.
    @Test func elementNamesUnderAFileSystemTreeAreRefusedRatherThanIgnored() {
        #expect(codes(valid(manifest: .init(
            kind: .fileSystemTree,
            rootElement: "Binder",
            itemElement: "BinderItem"))).allSatisfy { $0 == "corpus-manifest-field-ignored" })
    }

    @Test func anEmptyTrashTypeIsRefusedBecauseItExcludesNothing() {
        #expect(codes(valid(manifest: .init(
            kind: .xmlManifest,
            pathTemplate: "{name}.scrivx",
            rootElement: "Binder",
            itemElement: "BinderItem",
            idAttribute: "UUID",
            trashType: "  "))).contains("corpus-manifest-type-empty"))
    }

    // MARK: - Paths

    /// The reader refuses an escaping path at read time; refusing it here
    /// turns a mid-ceremony failure into a package that does not load.
    @Test func anAbsolutePartPathIsRefused() {
        #expect(codes(valid(parts: [
            .init(name: "text", pathTemplate: "/etc/passwd", format: .plainText),
        ])).contains("corpus-structure-path-absolute"))
    }

    @Test func aTraversingPartPathIsRefused() {
        #expect(codes(valid(parts: [
            .init(name: "text", pathTemplate: "Files/../../{id}", format: .rtf),
        ])).contains("corpus-structure-path-traverses"))
    }

    /// A PART IS PER-ITEM BY DEFINITION. A template with no `{id}` resolves to
    /// the same file for every item in the project, which reads as every
    /// chapter having identical text.
    @Test func aPartTemplateWithoutAnIdIsRefused() {
        #expect(codes(valid(parts: [
            .init(name: "text", pathTemplate: "Files/content.rtf", format: .rtf),
        ])).contains("corpus-structure-path-not-per-item"))
    }

    // MARK: - Discovery and open state

    @Test func discoveryByExtensionNeedsTheExtension() {
        var structure = valid()
        structure.projectExtension = nil
        #expect(codes(structure).contains("corpus-structure-extension-missing"))
    }

    @Test func anExtensionIsWrittenWithoutItsDot() {
        var structure = valid()
        structure.projectExtension = ".scriv"
        #expect(codes(structure).contains("corpus-structure-extension-malformed"))
    }

    /// A lock-file test with no path answers "not open" for every project
    /// forever — silently, since nothing failed.
    @Test func aLockFileOpenStateNeedsItsPath() {
        #expect(codes(valid(lockFilePath: nil))
            .contains("corpus-structure-lock-path-missing"))
    }

    @Test func anEmptyOpenStateIsRefused() {
        #expect(codes(valid(openState: [], lockFilePath: nil))
            .contains("corpus-structure-open-state-empty"))
    }

    // MARK: - Ceremonies

    @Test func aCeremonyWithNoMenuPathIsRefused() {
        #expect(codes(valid(ceremonies: [.init(act: .trash, menuPath: [])]))
            .contains("corpus-structure-ceremony-pathless"))
    }

    @Test func anEmptyMenuLevelIsRefused() {
        #expect(codes(valid(ceremonies: [
            .init(act: .trash, menuPath: ["Documents", "  "]),
        ])).contains("corpus-structure-ceremony-level-empty"))
    }

    /// TWO PATHS FOR ONE ACT is a package disagreeing with itself, and the
    /// reader would silently take whichever came first.
    @Test func twoCeremoniesForOneActAreRefused() {
        #expect(codes(valid(ceremonies: [
            .init(act: .trash, menuPath: ["Documents", "Move to Trash"]),
            .init(act: .trash, menuPath: ["Edit", "Delete"]),
        ])).contains("corpus-structure-ceremony-duplicated"))
    }

    // MARK: - Handles and URLs

    @Test func anUnknownURLPlaceholderIsRefused() {
        #expect(codes(valid(documentURLTemplate: "x-app:///{project}?id={id}&at={line}"))
            .contains("corpus-structure-url-placeholder-unknown"))
    }

    @Test func aHandlePrefixIsOneLetter() {
        #expect(codes(valid(handlePrefix: "DOC"))
            .contains("corpus-structure-handle-prefix-invalid"))
    }

    // MARK: - The wire

    /// THE DIGEST IS TAKEN OVER THESE BYTES. A corpus that declares no
    /// structure must encode exactly as it did before the sub-block existed,
    /// or every package that does not declare one changes digest.
    @Test func aCorpusWithoutStructureEncodesWithoutTheKey() throws {
        let corpus = PluginCorpusSchema(include: ["swift"], notation: "swift")
        let data = try JSONEncoder().encode(corpus)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["structure"] == nil)
    }

    /// `.sortedKeys` because an unordered re-encode is not a digest: the same
    /// declaration must produce the same bytes twice, which is the property
    /// the digest depends on and the one a round-trip can actually check.
    @Test func aStructureRoundTripsToTheSameBytes() throws {
        let corpus = PluginCorpusSchema(
            include: ["rtf"], notation: "prose", structure: valid())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(corpus)
        let decoded = try JSONDecoder().decode(PluginCorpusSchema.self, from: data)
        #expect(decoded == corpus)
        #expect(try encoder.encode(decoded) == data)
    }

    /// An unknown key is a typo, and a typo in a declaration is a field that
    /// silently does nothing — the same bargain every other block makes.
    @Test func anUnknownStructureKeyIsRefused() throws {
        let json = """
        {"include":["rtf"],"notation":"prose","structure":{
          "discovery":"directoryExtension","projectExtension":"scriv",
          "manifest":{"kind":"fileSystemTree"},"handlePrefixx":"D"}}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginCorpusSchema.self, from: Data(json.utf8))
        }
    }
}
