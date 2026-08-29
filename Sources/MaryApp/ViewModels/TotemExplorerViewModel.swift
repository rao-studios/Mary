//
//  TotemExplorerViewModel.swift
//  Mary
//
//  The Totems panel's single data layer: nodes, library, graph, write ledger
//  and the per-turn retrieval story, one VM for all five tabs.
//
//  `CorpusViewModel`'s shape, for its stated reasons: a 1 Hz poll of
//  lock-boxed stores, ONE impure `gather()`, a PURE `build(_:)` over an
//  `Inputs` value, and an Equatable diff before republishing so a quiet
//  second repaints nothing. Live data never round-trips through Granite's
//  `@Store` — its 200 ms debounce blurs precisely what a debugger exists to
//  show. On top of the poll sit the async fetchers this pane needs and the
//  Corpus pane does not: a ~5 s fleet/disk loop (ServersViewModel's authTask
//  cadence), user-driven library paging and document drill, and a
//  cancel-replace graph query — each writes a raw snapshot and calls
//  `refresh()`, so the pure core stays the only place rows are shaped.
//
//  Every network fetcher degrades to a NAMED notice (Seer offline, Totem
//  down, not signed in), never a blank pane and never a throw into a view.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import Foundation
import SwiftUI
import MaryRuntime

// MARK: - View model

@MainActor
final class TotemExplorerViewModel: ObservableObject {

    // Nodes
    @Published private(set) var fleetHeader: TotemFleetHeader?
    @Published private(set) var nodeRows: [TotemNodeRow] = []
    @Published private(set) var diskRows: [TotemDiskRow] = []
    @Published private(set) var diskSummary: TotemDiskSummary?
    @Published private(set) var nodesNotice: String?

    // Library
    @Published private(set) var familyChips: [TotemFamilyChip] = []
    @Published private(set) var laneSections: [TotemLaneSection] = []
    @Published private(set) var libraryHasMore = false
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var libraryNotice: String?
    @Published private(set) var selectedDocument: TotemDocumentDetail?
    @Published private(set) var isLoadingDocument = false

    // Graph
    @Published private(set) var graph: GraphQueryResult?
    @Published private(set) var isQuerying = false
    @Published private(set) var graphNotice: String?
    @Published private(set) var mutationNotice: String?
    @Published private(set) var isMutating = false
    /// The shape behind the current graph result — the Graph tab names what
    /// it is showing from this, and repair re-runs re-ask it. Written when
    /// the query is asked; the cancel-replace fence keeps the landed result
    /// the newest asked shape, and a failure names itself in `graphNotice`.
    @Published private(set) var lastGraphRequest: TotemGraphRequestShape?

    // Ledger

    // Retrieval
    @Published private(set) var retrievalRows: [TotemRetrievalTurnRow] = []

    /// For gating repair buttons in the view without a second status stream.
    @Published private(set) var isTotemHealthy = false

    /// SEEDED VIA `configure(...)` from the pane's config relay —
    /// `ConfigService` state lives behind a Granite `@Relay` only views hold,
    /// and this VM must not grow a Granite dependency for two scalars. The
    /// disk scanner still answers with an empty configured id (the persisted
    /// node-id file wins), so a pane that never seeds these degrades, it
    /// does not break.
    private(set) var configuredTotemNodeID: String = ""
    private(set) var totemHTTPPort: Int = ServerSpec.Defaults.totemPort

    /// The config-seeding entry point — re-entrant on purpose, so the pane
    /// re-seeds a running VM when config changes. Repairs and the live-node
    /// diff read the seeded values at call time, and the disk-skip key
    /// carries the node id, so a re-seed re-elects the live node on the next
    /// ~5 s pass even over an unchanged directory.
    func configure(nodeID: String, port: Int) {
        configuredTotemNodeID = nodeID
        totemHTTPPort = port
    }

    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var nodesTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?

    // Raw async snapshots — written by the fetchers, read only by `gather()`.
    private var fleetSnapshot: TotemFleetSnapshot?
    private var fleetNotice: String?
    private var diskSnapshot: TotemDiskInventory?
    private var libraryGroups: [GroupSummary] = []
    private var libraryHasMoreRaw = false
    private var libraryCursor = ""
    private var graphSnapshot: GraphQueryResult?
    /// The skip key for the ~5 s disk pass: the fingerprint the previous
    /// scan was taken under, and the node id it elected against — a config
    /// re-seed must rescan even when the directory has not moved.
    private var diskFingerprint: TotemDiskScanner.Fingerprint?
    private var diskScanNodeID: String?
    /// Cancel-replace fence: a slow 3-hop result must not land over a newer
    /// query, and gRPC calls do not reliably observe Task cancellation.
    private var queryGeneration = 0

    // MARK: - Lifecycle

    func start() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
        statusTask = Task { [weak self] in
            let stream = await MaryRuntime.localStack.statusStream()
            for await snapshots in stream {
                guard let self, !Task.isCancelled else { return }
                self.isTotemHealthy =
                    snapshots.first { $0.kind == .totem }?.status == .healthy
            }
        }
        nodesTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNodes()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        statusTask?.cancel()
        statusTask = nil
        nodesTask?.cancel()
        nodesTask = nil
        queryTask?.cancel()
        queryTask = nil
    }

    func refresh() {
        let built = Self.build(gather())
        if built.fleetHeader != fleetHeader { fleetHeader = built.fleetHeader }
        if built.nodeRows != nodeRows { nodeRows = built.nodeRows }
        if built.diskRows != diskRows { diskRows = built.diskRows }
        if built.diskSummary != diskSummary { diskSummary = built.diskSummary }
        if built.nodesNotice != nodesNotice { nodesNotice = built.nodesNotice }
        if built.familyChips != familyChips { familyChips = built.familyChips }
        if built.laneSections != laneSections { laneSections = built.laneSections }
        if built.libraryHasMore != libraryHasMore { libraryHasMore = built.libraryHasMore }
        if built.graph != graph { graph = built.graph }
        if built.retrievalRows != retrievalRows { retrievalRows = built.retrievalRows }
    }

    // MARK: - Impure

    struct Inputs {
        var routes: [AmbientTraceRecord] = []
        var retrieval: [TotemRetrievalCapture] = []
        var fleet: TotemFleetSnapshot? = nil
        var fleetNotice: String? = nil
        var disk: TotemDiskInventory? = nil
        var configuredNodeID: String = ""
        var groups: [GroupSummary] = []
        var hasMoreGroups: Bool = false
        var graph: GraphQueryResult? = nil
        var now: Date = Date()
    }

    private func gather() -> Inputs {
        Inputs(
            routes: AmbientTraceLog.shared.entries(),
            retrieval: RetrievalTraceLedger.shared.entries()
                .map(TotemRetrievalCapture.init(record:)),
            fleet: fleetSnapshot,
            fleetNotice: fleetNotice,
            disk: diskSnapshot,
            configuredNodeID: configuredTotemNodeID,
            groups: libraryGroups,
            hasMoreGroups: libraryHasMoreRaw,
            graph: graphSnapshot,
            now: Date())
    }

    // MARK: - Nodes fetch (~5 s loop; also the pane's Refresh affordance)

    func refreshNodes() async {
        let nodeID = configuredTotemNodeID
        let previousFingerprint = diskFingerprint
        let previousNodeID = diskScanNodeID
        let hasInventory = diskSnapshot != nil

        // Fleet GET and disk scan share nothing — siblings on purpose, so a
        // dead Seer's 5 s timeout never holds the disk section hostage.
        let fleetTask = Task { try await MaryRuntime.seerTotems.fleet() }

        // Stat-only but synchronous: one readdir per directory plus a stat
        // per DB file must not ride the main actor. The two-stat fingerprint
        // gates the full pass — an unchanged directory under an unchanged
        // elected identity reuses the previous inventory. Fingerprint before
        // scan: a write landing between the two makes the NEXT pass rescan,
        // never miss.
        let (scanned, fingerprint) = await Task.detached(
            priority: .utility
        ) { () -> (TotemDiskInventory?, TotemDiskScanner.Fingerprint) in
            let fingerprint = TotemDiskScanner.fingerprint()
            if hasInventory, nodeID == previousNodeID, fingerprint == previousFingerprint {
                return (nil, fingerprint)
            }
            return (TotemDiskScanner.scan(configuredNodeID: nodeID), fingerprint)
        }.value
        if let scanned { diskSnapshot = scanned }
        diskFingerprint = fingerprint
        diskScanNodeID = nodeID
        refresh()

        do {
            fleetSnapshot = try await fleetTask.value
            fleetNotice = nil
        } catch {
            // The stale fleet stays on screen beside the notice — a dead Seer
            // must not blank a list the disk section still corroborates.
            fleetNotice = "Seer offline — node list unavailable"
        }
        refresh()
    }

    // MARK: - Library (user-driven, never polled)

    func loadLibrary(reset: Bool) {
        guard !isLoadingLibrary else { return }
        // A reset is also the retry affordance: the stale notice clears NOW,
        // not when the refetch answers, so the pane shows loading rather
        // than the old failure sitting over a spinner.
        if reset { libraryNotice = nil }
        isLoadingLibrary = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchLibraryPage(reset: reset)
            self.isLoadingLibrary = false
        }
    }

    func loadMore() {
        guard libraryHasMore else { return }
        loadLibrary(reset: false)
    }

    private func fetchLibraryPage(reset: Bool) async {
        let (owner, notice) = await totemReadPreflight()
        guard let owner else {
            libraryNotice = notice
            return
        }
        let cursor = reset ? "" : libraryCursor
        do {
            let page = try await MaryRuntime.makeTotemReader()
                .library(ownerID: owner, limit: 50, afterID: cursor)
            if reset {
                libraryGroups = page.groups
            } else {
                // Dedupe on append — the defensive paging `clearGroups` also
                // does, so a non-advancing cursor cannot double the pane.
                let known = Set(libraryGroups.map(\.id))
                libraryGroups += page.groups.filter { !known.contains($0.id) }
            }
            libraryHasMoreRaw = page.hasMore
            libraryCursor = page.groups.last?.id ?? cursor
            libraryNotice = nil
        } catch {
            libraryNotice = "Couldn't read the library: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Document drill (two-tier, ContributionInspector's fallback)

    func loadDocument(id: String) {
        guard !isLoadingDocument else { return }
        isLoadingDocument = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchDocument(id: id)
            self.isLoadingDocument = false
        }
    }

    func clearSelectedDocument() {
        selectedDocument = nil
    }

    private func fetchDocument(id: String) async {
        let family = TotemAddressClassifier.classifyDocument(id: id).family
        let (owner, notice) = await totemReadPreflight()
        guard let owner else {
            selectedDocument = TotemDocumentDetail(
                id: id, name: id, groupLabel: "", createdAt: nil,
                body: nil, preview: nil, family: family, notice: notice)
            return
        }
        let reader = MaryRuntime.makeTotemReader()

        // Primary: real content by id (TotemLibrary.Documents).
        if let contents = try? await reader.documents(ids: [id], ownerID: owner),
           let document = contents.first {
            selectedDocument = TotemDocumentDetail(
                id: document.id,
                name: document.name.isEmpty ? document.id : document.name,
                groupLabel: document.groupLabel,
                createdAt: Self.documentDate(fromCreatedAt: document.createdAt),
                body: document.content,
                preview: nil,
                family: family,
                notice: nil)
            return
        }

        // Fallback (Totem binary predating the Documents RPC): library
        // metadata plus a name-seeded search preview — the inspector's tier
        // two, seeded with the document name because this pane has no reply
        // text to seed with.
        var name = ""
        var groupLabel = ""
        var createdAt: Date?
        if let groups = try? await reader.groups(containing: [id], ownerID: owner) {
            for group in groups {
                for document in group.documents where document.id == id {
                    name = document.name
                    groupLabel = group.label
                    createdAt = Self.documentDate(fromCreatedAt: document.createdAt)
                }
            }
        }
        var preview: String?
        let seed = name.isEmpty ? id : name
        if let hits = try? await reader.search(query: seed, ownerID: owner, topK: 12) {
            preview = hits.first { $0.documentID == id }?.text
        }
        selectedDocument = TotemDocumentDetail(
            id: id,
            name: name.isEmpty ? id : name,
            groupLabel: groupLabel,
            createdAt: createdAt,
            body: nil,
            preview: preview,
            family: family,
            notice: "Full body unavailable on this Totem build — metadata and a search preview only.")
    }

    // MARK: - Graph query (on-demand, cancel-replace)

    func runGraphQuery(seed: String, kind: String?, hops: Int, includeDocuments: Bool) {
        let shape = Self.shapeGraphRequest(
            seed: seed, kind: kind, hops: hops, includeDocuments: includeDocuments)
        lastGraphRequest = shape
        runGraphQuery(shape)
    }

    private func runGraphQuery(_ shape: TotemGraphRequestShape) {
        queryTask?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        isQuerying = true
        queryTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchGraph(shape, generation: generation)
        }
    }

    private func fetchGraph(_ shape: TotemGraphRequestShape, generation: Int) async {
        let (owner, notice) = await totemReadPreflight()
        guard let owner else {
            guard generation == queryGeneration else { return }
            graphNotice = notice
            isQuerying = false
            return
        }
        do {
            // Exact-name mode deliberately unused — see `shapeGraphRequest`.
            let result = try await MaryRuntime.makeTotemReader().graphQuery(
                entity: "",
                query: shape.query,
                kinds: shape.kinds,
                hops: shape.hops,
                limit: shape.limit,
                includeDocuments: shape.includeDocuments,
                ownerID: owner)
            guard generation == queryGeneration else { return }
            graphSnapshot = result
            graphNotice = nil
        } catch {
            guard generation == queryGeneration else { return }
            graphNotice = "Graph query failed: \(error.localizedDescription)"
        }
        isQuerying = false
        refresh()
    }

    // MARK: - Graph repair (UI gates every call behind a confirmation dialog)

    func renameEntity(id: String, name: String) {
        performRepair { port in
            try await TotemGraphAdmin.renameEntity(id: id, name: name, port: port)
        }
    }

    func mergeEntities(from: String, into: String) {
        performRepair { port in
            try await TotemGraphAdmin.mergeEntities(from: from, into: into, port: port)
        }
    }

    func deleteEntity(id: String) {
        performRepair { port in
            try await TotemGraphAdmin.deleteEntity(id: id, port: port)
        }
    }

    func setEntityKind(id: String, kind: String) {
        performRepair { port in
            try await TotemGraphAdmin.setEntityKind(id: id, kind: kind, port: port)
        }
    }

    func deleteRelationship(id: String) {
        performRepair { port in
            try await TotemGraphAdmin.deleteRelationship(id: id, port: port)
        }
    }

    /// The one repair that needs an owner (the route's DatabaseRequest
    /// envelope) — and the one with a 120 s deadline, priced by the server
    /// replaying its LLM extractor before answering.
    func reextractDocument(id: String) {
        guard !isMutating else { return }
        isMutating = true
        Task { [weak self] in
            guard let self else { return }
            let (owner, notice) = await self.totemReadPreflight()
            guard let owner else {
                self.mutationNotice = notice
                self.isMutating = false
                return
            }
            await self.finishRepair { port in
                try await TotemGraphAdmin.reextractDocument(
                    documentID: id, ownerID: owner, port: port)
            }
        }
    }

    private func performRepair(
        _ operation: @escaping @Sendable (Int) async throws -> MutationResult
    ) {
        guard !isMutating else { return }
        isMutating = true
        Task { [weak self] in
            guard let self else { return }
            await self.finishRepair(operation)
        }
    }

    private func finishRepair(
        _ operation: (Int) async throws -> MutationResult
    ) async {
        do {
            let result = try await operation(totemHTTPPort)
            mutationNotice = Self.mutationLine(result)
        } catch {
            mutationNotice = error.localizedDescription
        }
        isMutating = false
        // The graph on screen described the pre-mutation world; re-ask the
        // same question rather than trusting the response shape.
        if let shape = lastGraphRequest { runGraphQuery(shape) }
    }

    // MARK: - Guards

    /// The two preconditions every Totem gRPC read shares. Failing either
    /// yields a NAMED notice — the pane never shows an unexplained empty.
    private func totemReadPreflight() async -> (owner: String?, notice: String?) {
        guard isTotemHealthy else {
            return (nil, "Totem isn't running — start it from the Servers sheet.")
        }
        guard let owner = await MaryRuntime.seerSession.userID else {
            return (nil, "Sign in to Seer first — Totem holds documents per owner.")
        }
        return (owner, nil)
    }

    // MARK: - The pure core

    struct Built: Equatable {
        var fleetHeader: TotemFleetHeader?
        var nodeRows: [TotemNodeRow] = []
        var diskRows: [TotemDiskRow] = []
        var diskSummary: TotemDiskSummary?
        var nodesNotice: String?
        var familyChips: [TotemFamilyChip] = []
        var laneSections: [TotemLaneSection] = []
        var libraryHasMore = false
        var graph: GraphQueryResult?
        var retrievalRows: [TotemRetrievalTurnRow] = []
    }

    nonisolated static func build(_ inputs: Inputs) -> Built {
        var built = Built()
        buildNodes(inputs, into: &built)
        buildLibrary(inputs, into: &built)
        built.graph = inputs.graph
        built.retrievalRows = retrievalRows(inputs)
        return built
    }

    // MARK: Nodes

    nonisolated private static func buildNodes(_ inputs: Inputs, into built: inout Built) {
        // Config beats the node-id file, exactly as the server loads: the
        // scanner already applied that rule, so its verdict leads. Before a
        // scan lands the configured id stands in — through the SAME
        // acceptance rule the server loads by, not a third spelling of it.
        let liveID = inputs.disk?.liveNodeID
            ?? TotemNodeIdentity.canonical(inputs.configuredNodeID)

        if let fleet = inputs.fleet {
            built.fleetHeader = TotemFleetHeader(
                mothershipID: fleet.mothershipID,
                totalDocumentCount: fleet.totalDocumentCount,
                totalGroupCount: fleet.totalGroupCount,
                enabled: fleet.enabled,
                nodeCount: fleet.nodes.count)
            built.nodeRows = fleet.nodes.map { node in
                TotemNodeRow(
                    id: node.id,
                    host: node.host,
                    portLine: "gRPC \(node.grpcPort) · HTTP \(node.httpPort)",
                    lastSeen: node.lastSeen,
                    lastSeenLine: "seen \(ageLine(max(0, inputs.now.timeIntervalSince(node.lastSeen)))) ago",
                    isActive: node.isActive,
                    acceptingStorage: node.acceptingStorage,
                    isConfiguredNode: node.id.uppercased() == liveID,
                    stats: node.stats,
                    statsLine: node.stats.map {
                        "\($0.documentCount) docs · \($0.groupCount) groups · \($0.ownerCount) owners"
                    })
            }
        }

        if let disk = inputs.disk {
            // The scanner already ordered live-first, newest orphan next —
            // re-sorting here would be a second spelling of its rule.
            built.diskRows = disk.nodes.map { node in
                var layers: [String] = []
                if node.hasTable { layers.append("table") }
                if node.hasGraph { layers.append("graph") }
                if node.hasRegistry { layers.append("registry") }
                return TotemDiskRow(
                    id: node.id,
                    isLive: node.isLive,
                    layersLine: layers.joined(separator: " · "),
                    bytes: node.totalBytes,
                    sizeLine: byteLine(node.totalBytes),
                    lastModified: node.lastModified,
                    modifiedLine: node.lastModified.map {
                        "\(ageLine(max(0, inputs.now.timeIntervalSince($0)))) ago"
                    })
            }
            built.diskSummary = TotemDiskSummary(
                root: disk.root,
                liveNodeID: disk.liveNodeID,
                nodeCount: disk.nodes.count,
                orphanCount: disk.orphanedNodes.count,
                documentCount: disk.documentCount,
                partsCount: disk.partsCount,
                totalBytes: disk.totalBytes,
                totalLine: byteLine(disk.totalBytes))
        }

        built.nodesNotice = inputs.fleetNotice
    }

    // MARK: Library

    nonisolated private static func buildLibrary(_ inputs: Inputs, into built: inout Built) {
        let rows = inputs.groups.map { group -> TotemGroupRow in
            let classification = TotemAddressClassifier.classifyGroup(id: group.id)
            return TotemGroupRow(
                id: group.id,
                label: group.label.isEmpty ? group.id : group.label,
                documentCount: group.documents.count,
                family: classification.family,
                familyTitle: familyTitle(classification.family),
                lane: classification.lane,
                isSeerOwned: classification.isSeerOwned,
                isLegacy: classification.isLegacy,
                documents: group.documents.map { document in
                    let family = TotemAddressClassifier.classifyDocument(id: document.id).family
                    return TotemDocumentRow(
                        id: document.id,
                        name: document.name.isEmpty ? document.id : document.name,
                        createdAt: documentDate(fromCreatedAt: document.createdAt),
                        family: family,
                        familyTitle: familyTitle(family))
                })
        }

        // One chip per family PRESENT, in the enum's declared order — the
        // pane offers what exists rather than a fixed roster of empties.
        built.familyChips = TotemAddressFamily.allCases.compactMap { family in
            let count = rows.filter { $0.family == family }.count
            guard count > 0 else { return nil }
            return TotemFamilyChip(family: family, title: familyTitle(family), count: count)
        }

        // Lane buckets, fixed order. Seer-owned groups are NOT a Mary lane
        // (the server has no lanes), and unknown addresses are shown as what
        // they are instead of being misfiled — the classifier's own rule.
        let sections: [(id: String, title: String, subtitle: String, groups: [TotemGroupRow])] = [
            ("ability", "Ability lane",
             "Craft receipts and packaged skill memory, keyed by Ability and paradigm. Leftover application-group ids from before this lane sit here, marked legacy.",
             rows.filter { $0.lane == .ability }),
            ("personal", "Personal lane",
             "The user's own record — scopes, snapshots, units, style.",
             rows.filter { $0.lane == .personal }),
            ("seer", "Seer's own",
             "Written by the Seer server on its own; never Mary's to rewrite.",
             rows.filter { $0.isSeerOwned }),
            ("unknown", "Unrecognized",
             "No minter Mary knows about — foreign or future addresses.",
             rows.filter { $0.family == .unknown }),
        ]
        built.laneSections = sections
            .filter { !$0.groups.isEmpty }
            .map { TotemLaneSection(id: $0.id, title: $0.title, subtitle: $0.subtitle, groups: $0.groups) }

        built.libraryHasMore = inputs.hasMoreGroups
    }

    /// The view's chip filter — pure, so selection is a question the view
    /// asks, not state the builder stores. Nil family = everything.
    nonisolated static func sections(
        _ sections: [TotemLaneSection], matching family: TotemAddressFamily?
    ) -> [TotemLaneSection] {
        guard let family else { return sections }
        return sections.compactMap { section in
            let groups = section.groups.filter { $0.family == family }
            guard !groups.isEmpty else { return nil }
            var filtered = section
            filtered.groups = groups
            return filtered
        }
    }

    nonisolated static func familyTitle(_ family: TotemAddressFamily) -> String {
        switch family {
        case .abilityGroup: return "Ability"
        case .legacyApplicationGroup: return "Ability (legacy)"
        case .scopeGroup: return "Scope"
        case .legacyContextPool: return "Context pool"
        case .seerMemory: return "Memory"
        case .seerResonance: return "Resonance"
        case .abilityDocument: return "Ability document"
        case .abilitySchemaManifest: return "Schema manifest"
        case .abilitySchema: return "Ability schema"
        case .legacyApplicationDocument: return "Ability document (legacy)"
        case .legacyApplicationSchemaManifest: return "Schema manifest (legacy)"
        case .legacyApplicationSchema: return "Ability schema (legacy)"
        case .projectSchema: return "Project schema"
        case .stateSnapshot: return "State snapshot"
        case .skillRecord: return "Skill record"
        case .unitManifest: return "Unit manifest"
        case .unitCard: return "Unit card"
        case .styleProfile: return "Style profile"
        case .unknown: return "Unknown"
        }
    }

    // MARK: Graph helpers

    /// UI never offers hops 0 (the wire maps 0 → 1, but relying on the
    /// server to repair a request is how two layers drift), and the seed
    /// goes out as FREE TEXT — the wire's exact-name mode is deliberately
    /// never used: exact-name match returns nothing for a near miss and one
    /// field cannot know which it holds — semantic match covers both, priced
    /// by the client's 30 s deadline.
    nonisolated static func shapeGraphRequest(
        seed: String, kind: String?, hops: Int, includeDocuments: Bool
    ) -> TotemGraphRequestShape {
        TotemGraphRequestShape(
            query: seed.trimmingCharacters(in: .whitespacesAndNewlines),
            kinds: kind.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
            hops: min(3, max(1, hops)),
            limit: 20,
            includeDocuments: includeDocuments)
    }

    /// Edge endpoints may be pruned by `limit` — the id is the honest
    /// fallback, never a force-unwrap.
    nonisolated static func entityName(_ id: String, in result: GraphQueryResult?) -> String {
        result?.entities.first { $0.id == id }?.name ?? id
    }

    /// `success: false` with a nil surviving id is Totem's "no such entity"
    /// — data, not a transport failure, and the pane says so.
    nonisolated static func mutationLine(_ result: MutationResult) -> String {
        guard result.success else {
            return result.survivingID == nil
                ? "No such entity — the graph may have changed since this query."
                : "Totem refused the mutation."
        }
        var parts = ["Done."]
        if let surviving = result.survivingID {
            parts.append("Surviving entity \(surviving).")
        }
        if let count = result.entityCount {
            parts.append("\(count) entities now.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Ledger helpers

    // MARK: Retrieval

    nonisolated static func retrievalRows(_ inputs: Inputs) -> [TotemRetrievalTurnRow] {
        // Newest route wins a duplicated exchange id — both ring buffers are
        // newest-first, so `first` is the freshest claim.
        var routesByExchange: [UUID: AmbientTraceRecord] = [:]
        for record in inputs.routes {
            guard let exchangeID = record.exchangeID,
                  routesByExchange[exchangeID] == nil else { continue }
            routesByExchange[exchangeID] = record
        }

        var rows: [TotemRetrievalTurnRow] = []
        var joined: Set<UUID> = []
        for capture in inputs.retrieval {
            let route = routesByExchange[capture.exchangeID]
            if route != nil { joined.insert(capture.exchangeID) }
            rows.append(turnRow(capture: capture, route: route))
        }
        // Route rows with no ledger row are still turns — dropped, they would
        // hide exactly the case the pane explains ("why no retrieval?").
        for record in inputs.routes {
            if let exchangeID = record.exchangeID, joined.contains(exchangeID) { continue }
            rows.append(turnRow(capture: nil, route: record))
        }
        rows.sort { $0.date > $1.date }
        return Array(rows.prefix(120))
    }

    nonisolated private static func turnRow(
        capture: TotemRetrievalCapture?, route: AmbientTraceRecord?
    ) -> TotemRetrievalTurnRow {
        let plan = route?.route.gate.memory
        let requests = (capture?.requests ?? []).map { request -> TotemRetrievalRequestRow in
            TotemRetrievalRequestRow(
                id: request.id,
                transport: request.transport,
                aggregate: request.aggregate,
                groups: request.groups.map { group in
                    let family = TotemAddressClassifier.classifyGroup(id: group.id).family
                    return TotemScopeGroupTag(
                        id: group.id,
                        label: group.label,
                        family: family,
                        familyTitle: familyTitle(family))
                },
                relationshipHints: request.relationshipHints,
                isAnswered: capture?.contribution != nil
                    && capture?.contributionRequestID == request.id)
        }

        // Partial rows carry NAMED states — never blank, never dropped.
        var states: [String] = []
        if route == nil {
            states.append("no route row for this exchange")
        } else if capture == nil && route?.exchangeID == nil {
            states.append("recorded before the retrieval join — no exchange id")
        }
        if capture?.requests.isEmpty ?? true {
            states.append("no retrieval asked")
        }

        return TotemRetrievalTurnRow(
            // One of the pair is always present; the literal keeps the pure
            // core deterministic even if that ever stops holding.
            id: capture?.exchangeID.uuidString ?? route.map { $0.id.uuidString } ?? "unjoined",
            date: capture?.date ?? route?.date ?? Date.distantPast,
            utterance: route?.utterance,
            routeLine: route.map {
                "\($0.route.intent.rawValue) · \($0.route.decidedBy.rawValue) · \($0.route.rankingMode.rawValue)"
            },
            plan: plan.map { plan in
                TotemMemoryPlanRow(
                    lanes: plan.lanes.map(\.rawValue).sorted(),
                    abilityTargets: plan.abilityTargets.map(\.label),
                    expandDisciplineUsage: plan.expandDisciplineUsage,
                    lanePriority: plan.lanePriority.map(\.rawValue),
                    relationshipHints: plan.relationshipHints)
            },
            requests: requests,
            contribution: capture?.contribution,
            ambient: capture?.ambient ?? [],
            promptSpend: capture?.promptSpend ?? [],
            state: states.isEmpty ? nil : states.joined(separator: " · "),
            warnings: retrievalWarnings(
                plan: plan,
                requests: capture?.requests ?? [],
                contribution: capture?.contribution,
                ambient: capture?.ambient ?? [],
                promptSpend: capture?.promptSpend ?? []))
    }

    /// THE PANEL'S WHOLE POINT — pure derivations over one turn's plan,
    /// scope, contribution and prompt accounting. Computed per build, never
    /// stored.
    nonisolated static func retrievalWarnings(
        plan: TotemMemoryPlan?,
        requests: [TotemSeerRequestCapture],
        contribution: SeerContributionTrace?,
        ambient: [AmbientInjectionTrace],
        promptSpend: [PromptSpendTrace]
    ) -> [TotemRetrievalWarning] {
        var warnings: [TotemRetrievalWarning] = []
        let anyAggregate = requests.contains { $0.aggregate }
        // Family of every group actually sent. Keyed on FAMILY, not lane:
        // unit cards, style profiles and application schemas live at
        // application-family and manifest ADDRESSES, and a lane-keyed check
        // would call the corpus reachable whenever any personal-lane group
        // rode along — which is every focused turn.
        let sentFamilies = Set(requests.flatMap { request in
            request.groups.map { TotemAddressClassifier.classifyGroup(id: $0.id).family }
        })

        if let plan, plan.lanes == [.personal], !requests.isEmpty, !anyAggregate,
           !sentFamilies.contains(.abilityGroup),
           !sentFamilies.contains(.legacyApplicationGroup) {
            warnings.append(.init(
                kind: .behaviouralCorpusUnreachable,
                message: "Discipline-wide usage is out of reach — no Ability Totem group in the sent scope, and aggregate is off. Craft receipts live in mary-ability-… groups. Unit cards live in project scope; style lives on Personal."))
        }

        if let plan, !requests.isEmpty, !anyAggregate {
            let sentAbility = sentFamilies.contains(.abilityGroup)
                || sentFamilies.contains(.legacyApplicationGroup)
            if plan.lanes.contains(.ability), !sentAbility {
                warnings.append(.init(
                    kind: .planScopeMismatch,
                    message: "Plan asked for the Ability lane, but no Ability-family group went out."))
            } else if !plan.lanes.contains(.ability), sentAbility {
                warnings.append(.init(
                    kind: .planScopeMismatch,
                    message: "An Ability-family group went out that the plan never asked for."))
            }
        }

        if !requests.isEmpty, contribution == nil {
            warnings.append(.init(
                kind: .askedNothingBack,
                message: "Asked, nothing back — \(requests.count) request\(requests.count == 1 ? "" : "s") went out and no contribution returned."))
        }

        // The stored counts cannot separate a DEMOTED fact from a mention
        // that is one BY DESIGN (a background world's perception, the
        // eyeless aside): `AmbientRanker.render` books one key per fact
        // either way, so `keys.count` always equals blocks + mentions, and
        // block text is truncated INTO the budget rather than over it. What
        // the counts can say honestly: mentions exist while block capacity
        // was the binding constraint — every full-render slot spent, or char
        // slack too thin to seat another header (a tenth of the budget,
        // about one mention line). An aside beside a full roster is
        // indistinguishable from a demotion here, so the message claims a
        // full budget, never a drop.
        for injection in ambient where injection.mentionCount > 0 {
            let slack = injection.budget - injection.blockChars
            let blocksAtCap = injection.blockCount >= AmbientRanker.maxBlocks
            let charsBind = slack * 10 < injection.budget
            if blocksAtCap || charsBind {
                warnings.append(.init(
                    kind: .ambientBudgetPressure,
                    message: "Ambient budget pressure (\(injection.lane.rawValue)): held facts were demoted to mentions under a full block budget — \(injection.blockCount) blocks + \(injection.mentionCount) mentions, \(injection.blockChars)/\(injection.budget) chars."))
            }
        }

        for trace in promptSpend {
            let sectionSum = trace.spend.reduce(0) { $0 + $1.chars }
            if sectionSum + trace.appendedChars != trace.totalChars {
                warnings.append(.init(
                    kind: .waterfallMismatch,
                    message: "Prompt waterfall doesn't sum (\(trace.lane.rawValue)): \(sectionSum) sections + \(trace.appendedChars) appended ≠ \(trace.totalChars) total."))
            }
        }

        return warnings
    }

    // MARK: Formatting

    /// Locale-stable on purpose — rows are Equatable-diffed and pinned by
    /// tests, and `ByteCountFormatter` is neither.
    nonisolated static func byteLine(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [(1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB")]
        for (size, suffix) in units where bytes >= size {
            return String(format: "%.1f %@", Double(bytes) / Double(size), suffix)
        }
        return "\(bytes) B"
    }

    /// NOT `AmbientAge` — that scale tops out at 30 days by design (facts
    /// decay), and the disk museum's orphans are months old. An age this
    /// pane cannot spell would render as "an unknown time ago".
    /// Buckets are COARSE on purpose: these strings ride Equatable rows
    /// through the 1 Hz diff, and a per-second spelling republishes an
    /// unchanged fleet forever. Sub-minute collapses to one form; above it
    /// the floor moves at most once per minute, hour, day.
    nonisolated static func ageLine(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "moments" }
        if seconds < 60 { return "under a minute" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// Totem stamps `createdAt` in Unix seconds; zero means unstamped, and a
    /// magnitude that can only be milliseconds is decayed rather than
    /// rendered as the year 51982.
    nonisolated static func documentDate(fromCreatedAt createdAt: Int64) -> Date? {
        guard createdAt > 0 else { return nil }
        if createdAt > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000)
        }
        return Date(timeIntervalSince1970: TimeInterval(createdAt))
    }
}
