//
//  ThreadDiskInventory.swift
//  MaryRuntime
//
//  WHAT: What Thread's data directory holds, from file names and stat alone.
//  PIN:  Stat only — never decode plists. Suffixes stay literal strings
//        (placeholder graph-00000000-… must render as an orphan).
//

import Foundation

package struct ThreadDiskInventory: Equatable, Sendable {

    /// One table-/graph-/registry- triple, possibly incomplete — an orphan
    /// often kept only the layers that happened to flush before its identity
    /// was abandoned.
    package struct NodeDB: Equatable, Sendable, Identifiable {
        /// The filename suffix after the layer prefix, trimmed and uppercased
        /// so one node stays one node however the filesystem cased it.
        package var id: String
        package var hasTable = false
        package var hasGraph = false
        package var hasRegistry = false
        package var tableBytes: Int64 = 0
        package var graphBytes: Int64 = 0
        package var registryBytes: Int64 = 0
        /// Newest mtime across the layers present — when this DB last moved.
        package var lastModified: Date? = nil
        package var isLive = false
        package var totalBytes: Int64 { tableBytes + graphBytes + registryBytes }

        package init(
            id: String, hasTable: Bool = false, hasGraph: Bool = false,
            hasRegistry: Bool = false, tableBytes: Int64 = 0, graphBytes: Int64 = 0,
            registryBytes: Int64 = 0, lastModified: Date? = nil, isLive: Bool = false
        ) {
            self.id = id
            self.hasTable = hasTable
            self.hasGraph = hasGraph
            self.hasRegistry = hasRegistry
            self.tableBytes = tableBytes
            self.graphBytes = graphBytes
            self.registryBytes = registryBytes
            self.lastModified = lastModified
            self.isLive = isLive
        }
    }

    package var root: String
    /// Identity Thread would load (config beats node-id file). Nil = never minted.
    package var liveNodeID: String?
    /// Live node first, then orphans newest-modified first.
    package var nodes: [NodeDB] = []
    /// Shallow entries of `documents/` without a `-parts` suffix.
    package var documentCount = 0
    /// Shallow entries of `documents/` carrying the `-parts` suffix.
    package var partsCount = 0
    /// DB plist bytes only — `documents/` is counted, never sized, because
    /// sizing thousands of entries would turn a stat pass into a crawl.
    package var totalBytes: Int64 = 0

    package var orphanedNodes: [NodeDB] { nodes.filter { !$0.isLive } }

    package init(
        root: String, liveNodeID: String? = nil, nodes: [NodeDB] = [],
        documentCount: Int = 0, partsCount: Int = 0, totalBytes: Int64 = 0
    ) {
        self.root = root
        self.liveNodeID = liveNodeID
        self.nodes = nodes
        self.documentCount = documentCount
        self.partsCount = partsCount
        self.totalBytes = totalBytes
    }
}

/// Reads the directory synchronously — one readdir of `root`, one of
/// `documents/`, a stat per DB file — so callers must invoke `scan` off the
/// main thread.
package enum ThreadDiskScanner {

    /// The two directory mtimes, as one Equatable value — the poll loop's
    /// change detector.
    package struct Fingerprint: Equatable, Sendable {
        var rootModified: Date?
        var documentsModified: Date?
    }

    /// Directory mtime fingerprint — equal means reuse previous inventory. No readdir.
    package static func fingerprint(
        root: String = ServerSpec.expand(ServerSpec.Defaults.threadDataDir)
    ) -> Fingerprint {
        Fingerprint(
            rootModified: modificationDate(atPath: root),
            documentsModified: modificationDate(atPath: root + "/documents"))
    }

    private static func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    package static func scan(
        root: String = ServerSpec.expand(ServerSpec.Defaults.threadDataDir),
        configuredNodeID: String = ""
    ) -> ThreadDiskInventory {
        let liveNodeID = ThreadNodeIdentity.persisted(
            configured: configuredNodeID,
            nodeIDFilePath: root + "/node-id")
        var inventory = ThreadDiskInventory(root: root, liveNodeID: liveNodeID)

        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        var byID: [String: ThreadDiskInventory.NodeDB] = [:]
        for entry in entries {
            guard let (layer, suffix) = layerAndSuffix(of: entry.lastPathComponent) else {
                continue
            }
            let id = suffix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !id.isEmpty else { continue }

            let values = try? entry.resourceValues(forKeys: keys)
            let bytes = Int64(values?.fileSize ?? 0)
            var node = byID[id] ?? .init(id: id)
            switch layer {
            case .table:
                node.hasTable = true
                node.tableBytes += bytes
            case .graph:
                node.hasGraph = true
                node.graphBytes += bytes
            case .registry:
                node.hasRegistry = true
                node.registryBytes += bytes
            }
            if let modified = values?.contentModificationDate,
               modified > (node.lastModified ?? .distantPast) {
                node.lastModified = modified
            }
            byID[id] = node
        }

        var nodes = Array(byID.values)
        for index in nodes.indices {
            nodes[index].isLive = nodes[index].id == liveNodeID
        }
        // Live first, then newest orphan first; id breaks mtime ties so two
        // scans of the same disk always agree.
        nodes.sort { a, b in
            if a.isLive != b.isLive { return a.isLive }
            let aDate = a.lastModified ?? .distantPast
            let bDate = b.lastModified ?? .distantPast
            if aDate != bDate { return aDate > bDate }
            return a.id < b.id
        }
        inventory.nodes = nodes
        inventory.totalBytes = nodes.reduce(0) { $0 + $1.totalBytes }

        // Names only. Skip hidden — path readdir has no options; .DS_Store is not a document.
        let documentNames = (try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.appendingPathComponent("documents").path)) ?? []
        for name in documentNames where !name.hasPrefix(".") {
            if name.hasSuffix("-parts") {
                inventory.partsCount += 1
            } else {
                inventory.documentCount += 1
            }
        }

        return inventory
    }

    // MARK: - Name parsing

    private enum Layer {
        case table, graph, registry
    }

    private static let prefixes: [(String, Layer)] = [
        ("table-", .table), ("graph-", .graph), ("registry-", .registry),
    ]

    private static func layerAndSuffix(of name: String) -> (Layer, String)? {
        for (prefix, layer) in prefixes where name.hasPrefix(prefix) {
            return (layer, String(name.dropFirst(prefix.count)))
        }
        return nil
    }
}
