//
//  ProjectCorpusReader.swift
//  MaryPlugin
//
//  READING A WRITING PROJECT OFF DISK — the outline, and one item's text.
//
//  ⚠️ LOCATE-ONLY, AND THE REASON IS DATA LOSS. This reads and never writes,
//  and that is a designed limit rather than an unfinished one. An editor with
//  the project open autosaves on its own schedule; a write from outside races
//  that save and LOSES, silently, with no failing call anywhere — the user
//  finds a paragraph gone an hour later and nothing in any log says why.
//  Changes go through the application's own commands, which is slower and
//  cannot lose work.
//
//  EVERY PATH IS RESOLVED BENEATH THE PROJECT ROOT AND CHECKED. A declared
//  template is data, and data that composes a filesystem path is data that
//  can escape one — so a resolved path that does not stay inside the project
//  is refused rather than read. That is not paranoia about package authors;
//  it is that `{id}` comes from a manifest this code did not write.
//
//  NOTHING HERE NAMES AN APPLICATION. Element names, attribute names, path
//  templates and the trash's own type all arrive from
//  `PluginCorpusStructureSchema`. A second project format is a declaration.
//

import Foundation
import MaryFoundation

public enum ProjectCorpusReader {

    /// One item in the outline.
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// The declared type, verbatim — "Text", "Folder", "DraftFolder".
        public var type: String?
        public var isContainer: Bool
        /// Depth from the outline root, for rendering the shape.
        public var depth: Int
        public var children: [Item]

        public init(
            id: String, title: String, type: String?,
            isContainer: Bool, depth: Int, children: [Item] = []
        ) {
            self.id = id
            self.title = title
            self.type = type
            self.isContainer = isContainer
            self.depth = depth
            self.children = children
        }

        /// This item and everything under it, depth-first — the order the
        /// outline reads in.
        public var flattened: [Item] {
            [self] + children.flatMap(\.flattened)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noProject(String)
        case noManifest(String)
        case unreadableManifest(String)
        case noSuchItem(String)
        case noText(String)
        /// A declared template resolved outside the project. Never a user's
        /// doing, always a declaration's.
        case pathEscapesProject(String)

        public var spoken: String {
            switch self {
            case .noProject(let name):
                return "I couldn't find a project called \(name)."
            case .noManifest(let path):
                return "That project has no \(path) — it may not be the kind I can read."
            case .unreadableManifest(let detail):
                return "I couldn't read that project's outline: \(detail)"
            case .noSuchItem(let named):
                return "There's nothing called \(named) in that project."
            case .noText(let title):
                return "\"\(title)\" has no text yet."
            case .pathEscapesProject(let path):
                return "That project's layout points outside itself (\(path)), so I stopped."
            }
        }
    }

    // MARK: - The outline

    /// Read the project's outline.
    ///
    /// TRASH IS EXCLUDED, always and without a flag. A deleted chapter is not
    /// part of the work: counting it in a progress report or offering it as a
    /// destination would both be wrong, and there is no request for which
    /// including it is the right answer.
    ///
    /// `excludeNames`/`includeExtensions` matter ONLY for `.fileSystemTree` —
    /// an `.xmlManifest` outline is already bounded by the binder, so a
    /// manuscript's exclusions have nothing to filter. For a directory
    /// project they are the same names its corpus's own `exclude`/`include`
    /// already declare (`CorpusCrawl.projectFiles` reads the identical
    /// fields for the passive style crawl): without them a walk over a real
    /// checkout reads `.build`, `DerivedData` and `.git` right along with the
    /// source, which is slow and not what "the project's outline" means.
    public static func outline(
        projectRoot: URL, structure: PluginCorpusStructureSchema,
        excludeNames: [String] = [], includeExtensions: [String] = []
    ) -> Result<[Item], Failure> {
        switch structure.manifest.kind {
        case .xmlManifest:
            return xmlOutline(projectRoot: projectRoot, structure: structure)
        case .fileSystemTree:
            return .success(treeOutline(
                projectRoot: projectRoot, structure: structure,
                excludeNames: excludeNames, includeExtensions: includeExtensions))
        }
    }

    private static func xmlOutline(
        projectRoot: URL, structure: PluginCorpusStructureSchema
    ) -> Result<[Item], Failure> {
        let manifest = structure.manifest
        guard let template = manifest.pathTemplate else {
            return .failure(.noManifest("manifest path"))
        }
        // `{name}` is the project's own directory name without its extension
        // — a Scrivener project holds `<name>.scrivx`.
        let name = projectRoot.deletingPathExtension().lastPathComponent
        let relative = template.replacingOccurrences(of: "{name}", with: name)
        guard let manifestURL = resolved(relative, under: projectRoot) else {
            return .failure(.pathEscapesProject(relative))
        }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .failure(.noManifest(relative))
        }

        let parser: XMLDocumentTree
        do {
            parser = try XMLDocumentTree(contentsOf: manifestURL)
        } catch {
            return .failure(.unreadableManifest(error.localizedDescription))
        }
        guard let rootName = manifest.rootElement,
              let itemName = manifest.itemElement,
              let root = parser.firstDescendant(named: rootName)
        else { return .failure(.unreadableManifest("no \(manifest.rootElement ?? "root")")) }

        let containers = Set(manifest.containerTypes)
        func build(_ node: XMLDocumentTree.Node, depth: Int) -> [Item] {
            node.children(named: itemName).compactMap { element -> Item? in
                let type = manifest.typeAttribute.flatMap { element.attributes[$0] }
                // THE TRASH AND EVERYTHING BENEATH IT, dropped here rather
                // than filtered later — a later filter would have to know
                // the tree shape, and this one only has to know the type.
                if let trash = manifest.trashType, type == trash { return nil }

                let id = manifest.idAttribute.flatMap { element.attributes[$0] } ?? ""
                let title = manifest.titleElement
                    .flatMap { element.firstChild(named: $0)?.text }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let childrenNode = manifest.childrenElement
                    .flatMap { element.firstChild(named: $0) }
                return Item(
                    id: id,
                    title: title,
                    type: type,
                    isContainer: type.map(containers.contains) ?? false,
                    depth: depth,
                    children: childrenNode.map { build($0, depth: depth + 1) } ?? [])
            }
        }
        return .success(build(root, depth: 0))
    }

    /// The directory tree AS the outline — a folder of markdown, where an
    /// item's id is its path relative to the root.
    ///
    /// ⚠️ EXCLUDED NAMES ARE PRUNED, NOT FILTERED — `walker.skipDescendants()`
    /// has no direct analogue in a recursive build, so a matched directory
    /// simply never recurses. Filtering entries after a full recursive walk
    /// would still pay to enumerate every file inside `.build` or
    /// `DerivedData` before throwing the results away.
    private static func treeOutline(
        projectRoot: URL, structure: PluginCorpusStructureSchema,
        excludeNames: [String], includeExtensions: [String]
    ) -> [Item] {
        let excluded = Set(excludeNames)
        let included = Set(includeExtensions)
        func build(_ directory: URL, depth: Int) -> [Item] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> Item? in
                    guard !excluded.contains(url.lastPathComponent) else { return nil }
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory ?? false
                    // A FILE OUTSIDE THE DECLARED NOTATION is not part of the
                    // outline either — empty `included` (no corpus declares
                    // one) keeps every file, exactly as before this existed.
                    if !isDirectory, !included.isEmpty, !included.contains(url.pathExtension) {
                        return nil
                    }
                    // SYMLINKS RESOLVED ON BOTH SIDES, the same helper the
                    // passive crawl uses (`CorpusCrawl.relativePath`) — a
                    // naive prefix strip breaks the moment the root is
                    // reached through a symlink (`/tmp` as `/private/tmp`,
                    // exactly what a temporary-directory checkout hits),
                    // silently making every id an absolute path instead of a
                    // relative one.
                    let relative = CorpusCrawl.relativePath(
                        of: url.path, under: projectRoot.path)
                    let children = isDirectory ? build(url, depth: depth + 1) : []
                    // A FOLDER LEFT EMPTY BY FILTERING is not part of the
                    // outline — it holds nothing this corpus reads, and
                    // showing it as a container with nothing inside is worse
                    // than not showing it.
                    if isDirectory, children.isEmpty { return nil }
                    return Item(
                        id: relative,
                        title: url.deletingPathExtension().lastPathComponent,
                        type: isDirectory ? "folder" : "file",
                        isContainer: isDirectory,
                        depth: depth,
                        children: children)
                }
        }
        return build(projectRoot, depth: 0)
    }

    // MARK: - One item's text

    /// Read one item's text, from the first declared part that exists.
    public static func text(
        itemID: String, projectRoot: URL, structure: PluginCorpusStructureSchema
    ) -> Result<String, Failure> {
        guard !structure.parts.isEmpty else { return .failure(.noText(itemID)) }
        for part in structure.parts {
            let relative = part.pathTemplate.replacingOccurrences(of: "{id}", with: itemID)
            guard let url = resolved(relative, under: projectRoot) else {
                return .failure(.pathEscapesProject(relative))
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let decoded = decode(url, format: part.format) else { continue }
            return .success(decoded)
        }
        return .failure(.noText(itemID))
    }

    static func decode(_ url: URL, format: PluginCorpusTextFormat) -> String? {
        switch format {
        case .plainText, .markdown:
            return try? String(contentsOf: url, encoding: .utf8)
        case .rtf:
            // RTF THROUGH THE SYSTEM'S OWN READER, so a manuscript's
            // formatting, footnotes and annotations come back as the plain
            // words rather than as markup. A hand-rolled stripper gets
            // nested groups wrong and leaves control words in the prose.
            guard let data = try? Data(contentsOf: url),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil)
            else { return nil }
            return attributed.string
        }
    }

    // MARK: - Paths

    /// Resolve a declared relative path beneath the project, or nil if it
    /// would leave it.
    ///
    /// SYMLINKS RESOLVED BEFORE THE COMPARISON, because a path can be inside
    /// the project by spelling and outside it in fact.
    static func resolved(_ relative: String, under root: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path == base.path
                || resolved.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}
