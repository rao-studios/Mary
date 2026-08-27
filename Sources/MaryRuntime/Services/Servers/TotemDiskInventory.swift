//
//  TotemDiskInventory.swift
//  Mary
//
//  What `~/Documents/totem-db` actually holds, from file names and stat alone.
//
//  Totem persists a node as a table-/graph-/registry-<uuid> plist triple, and
//  every regenerated identity leaves its triple behind: the directory carries
//  one live node and a museum of orphans (~170 today) that no server will ever
//  open again. The running server reports only the node it loaded, so which
//  DBs exist, how big they are, and when they last changed can only be
//  answered here.
//
//  STAT ONLY — the plists run to multiple megabytes and the panel refreshes
//  this on a loop, so the scanner reads `.fileSizeKey` and
//  `.contentModificationDateKey` and never decodes a plist. Suffixes are kept
//  as literal strings rather than parsed UUIDs: the server's
//  `graph-00000000-…-000000000001` placeholder must render as an orphan, not
//  vanish because it failed a cast.
//

import Foundation

package struct TotemDiskInventory: Equatable, Sendable {

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
    /// The identity Totem would load (config beats the persisted node-id
    /// file), already canonical uppercase from `TotemNodeIdentity` so it
    /// compares against `NodeDB.id`. Nil when neither exists — never minted,
    /// so a fresh machine reports every DB as orphaned rather than inventing
    /// a live one.
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
package enum TotemDiskScanner {

    /// The two directory mtimes, as one Equatable value — the poll loop's
    /// change detector.
    package struct Fingerprint: Equatable, Sendable {
        var rootModified: Date?
        var documentsModified: Date?
    }

    /// Two stats, no readdir. Directory mtimes move on entry create, remove
    /// or rename — which includes atomic (temp + rename) plist replaces — so
    /// an equal fingerprint means nothing the scan reads has moved and the
    /// ~5 s loop can reuse its previous inventory instead of re-walking ~170
    /// orphan triples. An in-place rewrite that keeps its directory entry is
    /// invisible here by construction; the first entry-level change after it
    /// re-scans everything, so staleness is bounded by that, never permanent.
    package static func fingerprint(
        root: String = ServerSpec.expand("~/Documents/totem-db")
    ) -> Fingerprint {
        Fingerprint(
            rootModified: modificationDate(atPath: root),
            documentsModified: modificationDate(atPath: root + "/documents"))
    }

    private static func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    package static func scan(
        root: String = ServerSpec.expand("~/Documents/totem-db"),
        configuredNodeID: String = ""
    ) -> TotemDiskInventory {
        let liveNodeID = TotemNodeIdentity.persisted(
            configured: configuredNodeID,
            nodeIDFilePath: root + "/node-id")
        var inventory = TotemDiskInventory(root: root, liveNodeID: liveNodeID)

        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        var byID: [String: TotemDiskInventory.NodeDB] = [:]
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

        // Names only, no stat. Hidden entries are skipped by hand because the
        // path-based readdir has no options: `.DS_Store` must not count as a
        // document.
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
