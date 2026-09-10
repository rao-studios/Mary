//
//  ProjectCorpusReader.swift
//  MaryPlugin
//
//  WHAT: Read a writing project off disk — outline and one item's text.
//  IN:   PluginCorpusStructureSchema / XMLDocumentTree
//  OUT:  ProjectCorpusAdapter
//  PIN:  Locate-only. Paths stay under the project root. Nothing names an app.
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

    /// Project outline. Trash always excluded. `excludeNames`/`includeExtensions`
    /// apply only to `.fileSystemTree` (same fields as CorpusCrawl.projectFiles).
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
        // `{name}` is the project directory without extension (`<name>.scrivx`).
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
                // Drop trash and everything beneath it here — type is enough; a later filter needs the tree.
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

    /// Directory tree as outline; item id is path relative to root.
    /// PIN: excluded names are pruned (no recurse), not filtered after a full walk.
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
                    // File outside declared notation is not in the outline. Empty `included` keeps every file.
                    if !isDirectory, !included.isEmpty, !included.contains(url.pathExtension) {
                        return nil
                    }
                    // Same helper as CorpusCrawl.relativePath — resolve both sides.
                    let relative = CorpusCrawl.relativePath(
                        of: url.path, under: projectRoot.path)
                    let children = isDirectory ? build(url, depth: depth + 1) : []
                    // Folder left empty by filtering is not part of the outline.
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
            // RTF via the system reader — words, not markup.
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

    /// Resolve a declared relative path under the project, or nil if it would leave.
    /// PIN: resolve symlinks before comparing — spelling can lie.
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
