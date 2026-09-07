//
//  ThreadExplorerViewModel.swift
//  Mary
//
//  WHAT: Threads pane data — nodes, library, graph, ledger, retrieval (one VM).
//  OUT:  Threads*View. ThreadExplorerRows / ThreadRetrievalCaptures (siblings)
//  PIN:  Named notices on fetch fail, never a blank pane. Never Granite @Store.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryThread
import Foundation
import SwiftUI
import MaryRuntime

// MARK: - View model

@MainActor
final class ThreadExplorerViewModel: ObservableObject {

    // Nodes
    @Published private(set) var fleetHeader: ThreadFleetHeader?
    @Published private(set) var nodeRows: [ThreadNodeRow] = []
    @Published private(set) var diskRows: [ThreadDiskRow] = []
    @Published private(set) var diskSummary: ThreadDiskSummary?
    @Published private(set) var nodesNotice: String?

    // Library
    @Published private(set) var familyChips: [ThreadFamilyChip] = []
    @Published private(set) var laneSections: [ThreadLaneSection] = []
    @Published private(set) var libraryHasMore = false
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var libraryNotice: String?
    @Published private(set) var abilityDepositHint: String?
    @Published private(set) var selectedDocument: ThreadDocumentDetail?
    @Published private(set) var isLoadingDocument = false

    // Graph
    @Published private(set) var graph: GraphQueryResult?
    @Published private(set) var isQuerying = false
    @Published private(set) var graphNotice: String?
    @Published private(set) var mutationNotice: String?
    @Published private(set) var isMutating = false
    /// Shape of the graph on screen. Repair re-asks it. Failures name themselves in `graphNotice`.
    @Published private(set) var lastGraphRequest: ThreadGraphRequestShape?

    // Ledger

    // Retrieval
    @Published private(set) var retrievalRows: [ThreadRetrievalTurnRow] = []

    /// For gating repair buttons in the view without a second status stream.
    @Published private(set) var isThreadHealthy = false
    @Published private(set) var isFleetHealthy = false
    /// Gold overlay on the Life button while a discipline is training.
    @Published private(set) var lifeIsTraining = false
    /// What the idle engine is doing, for the same button's second dot.
    @Published private(set) var lifePhase: LifeEnginePhase = .off

    /// Seeded via `configure(...)` from the pane's config relay (no Granite on this VM).
    private(set) var configuredThreadNodeID: String = ""
    private(set) var threadHTTPPort: Int = ServerSpec.Defaults.threadPort

    /// Re-entrant config seed. Re-seed re-elects the live node on the next ~5 s disk pass.
    func configure(nodeID: String, port: Int) {
        configuredThreadNodeID = nodeID
        threadHTTPPort = port
    }

    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var nodesTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?

    // Raw async snapshots — written by the fetchers, read only by `gather()`.
    private var fleetSnapshot: ThreadFleetSnapshot?
    private var fleetNotice: String?
    private var diskSnapshot: ThreadDiskInventory?
    private var libraryGroups: [GroupSummary] = []
    private var libraryHasMoreRaw = false
    private var libraryCursor = ""
    private var graphSnapshot: GraphQueryResult?
    /// Disk-pass skip key (fingerprint + elected node id). Re-seed forces a rescan.
    private var diskFingerprint: ThreadDiskScanner.Fingerprint?
    private var diskScanNodeID: String?
    /// Cancel-replace fence: a slow 3-hop must not land over a newer query.
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
                self.isThreadHealthy =
                    snapshots.first { $0.kind == .thread }?.status == .healthy
                self.isFleetHealthy =
                    snapshots.first { $0.kind == .fleet }?.status == .healthy
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
        Task { [weak self] in
            let training = await MaryRuntime.lifeIsTraining()
            let phase = await MaryRuntime.lifeEngineSnapshot().phase
            guard let self else { return }
            if training != self.lifeIsTraining { self.lifeIsTraining = training }
            if phase != self.lifePhase { self.lifePhase = phase }
        }
    }

    // MARK: - Impure

    struct Inputs {
        var routes: [AmbientTraceRecord] = []
        var retrieval: [ThreadRetrievalCapture] = []
        var fleet: ThreadFleetSnapshot? = nil
        var fleetNotice: String? = nil
        var disk: ThreadDiskInventory? = nil
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
                .map(ThreadRetrievalCapture.init(record:)),
            fleet: fleetSnapshot,
            fleetNotice: fleetNotice,
            disk: diskSnapshot,
            configuredNodeID: configuredThreadNodeID,
            groups: libraryGroups,
            hasMoreGroups: libraryHasMoreRaw,
            graph: graphSnapshot,
            now: Date())
    }

    // MARK: - Nodes fetch (~5 s loop; also the pane's Refresh affordance)

    func refreshNodes() async {
        let nodeID = configuredThreadNodeID
        let previousFingerprint = diskFingerprint
        let previousNodeID = diskScanNodeID
        let hasInventory = diskSnapshot != nil

        // Fleet GET and disk scan are siblings — a dead Sewn must not hold the disk section.
        let fleetTask = Task { try await MaryRuntime.sewnThreads.fleet() }

        // Fingerprint off MainActor; unchanged dir+identity reuses inventory. Fingerprint before scan.
        let (scanned, fingerprint) = await Task.detached(
            priority: .utility
        ) { () -> (ThreadDiskInventory?, ThreadDiskScanner.Fingerprint) in
            let fingerprint = ThreadDiskScanner.fingerprint()
            if hasInventory, nodeID == previousNodeID, fingerprint == previousFingerprint {
                return (nil, fingerprint)
            }
            return (ThreadDiskScanner.scan(configuredNodeID: nodeID), fingerprint)
        }.value
        if let scanned { diskSnapshot = scanned }
        diskFingerprint = fingerprint
        diskScanNodeID = nodeID
        refresh()

        do {
            fleetSnapshot = try await fleetTask.value
            fleetNotice = nil
        } catch {
            // Stale fleet stays beside the notice; a dead Sewn must not blank the list.
            fleetNotice = "Sewn offline — node list unavailable"
        }
        refresh()
    }

    // MARK: - Library (user-driven, never polled)

    func loadLibrary(reset: Bool) {
        guard !isLoadingLibrary else { return }
        // Reset clears the stale notice now so the pane shows loading, not the old failure.
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
        let (owner, notice) = await threadReadPreflight()
        guard let owner else {
            libraryNotice = notice
            await refreshAbilityDepositHint()
            return
        }
        let cursor = reset ? "" : libraryCursor
        do {
            let page = try await MaryRuntime.makeThreadReader()
                .library(ownerID: owner, limit: 50, afterID: cursor)
            if reset {
                libraryGroups = page.groups
            } else {
                // Dedupe on append so a non-advancing cursor cannot double the pane.
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
        await refreshAbilityDepositHint()
    }

    private func refreshAbilityDepositHint() async {
        let hasAbilityGroup = libraryGroups.contains { $0.id.hasPrefix("mary-ability-") }
        // Preflight already named Thread-down / not-signed-in — don't stack a second line.
        if hasAbilityGroup || libraryNotice != nil {
            abilityDepositHint = nil
            return
        }
        abilityDepositHint = MaryRuntime.abilityDepositNoticeBox.withLock { $0 }
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
        let family = ThreadAddressClassifier.classifyDocument(id: id).family
        let (owner, notice) = await threadReadPreflight()
        guard let owner else {
            selectedDocument = ThreadDocumentDetail(
                id: id, name: id, groupLabel: "", createdAt: nil,
                body: nil, preview: nil, family: family, notice: notice)
            return
        }
        let reader = MaryRuntime.makeThreadReader()

        // Primary: real content by id (ThreadLibrary.Documents).
        if let contents = try? await reader.documents(ids: [id], ownerID: owner),
           let document = contents.first {
            let body = document.content
            selectedDocument = ThreadDocumentDetail(
                id: document.id,
                name: document.name.isEmpty ? document.id : document.name,
                groupLabel: document.groupLabel,
                createdAt: Self.documentDate(fromCreatedAt: document.createdAt),
                body: body,
                preview: nil,
                family: family,
                notice: nil,
                codec: BehavioralThreadInspect.codec(from: body),
                interaction: BehavioralThreadInspect.interaction(from: body))
            return
        }

        // Fallback: library metadata + name-seeded search preview (no reply text to seed).
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
        selectedDocument = ThreadDocumentDetail(
            id: id,
            name: name.isEmpty ? id : name,
            groupLabel: groupLabel,
            createdAt: createdAt,
            body: nil,
            preview: preview,
            family: family,
            notice: "Full body unavailable on this Thread build — metadata and a search preview only.",
            codec: preview.flatMap(BehavioralThreadInspect.codec(from:)),
            interaction: preview.flatMap(BehavioralThreadInspect.interaction(from:)))
    }

    // MARK: - Graph query (on-demand, cancel-replace)

    func runGraphQuery(seed: String, kind: String?, hops: Int, includeDocuments: Bool) {
        let shape = Self.shapeGraphRequest(
            seed: seed, kind: kind, hops: hops, includeDocuments: includeDocuments)
        lastGraphRequest = shape
        runGraphQuery(shape)
    }

    private func runGraphQuery(_ shape: ThreadGraphRequestShape) {
        queryTask?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        isQuerying = true
        queryTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchGraph(shape, generation: generation)
        }
    }

    private func fetchGraph(_ shape: ThreadGraphRequestShape, generation: Int) async {
        let (owner, notice) = await threadReadPreflight()
        guard let owner else {
            guard generation == queryGeneration else { return }
            graphNotice = notice
            isQuerying = false
            return
        }
        do {
            // Exact-name mode deliberately unused — see `shapeGraphRequest`.
            let result = try await MaryRuntime.makeThreadReader().graphQuery(
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
            try await ThreadGraphAdmin.renameEntity(id: id, name: name, port: port)
        }
    }

    func mergeEntities(from: String, into: String) {
        performRepair { port in
            try await ThreadGraphAdmin.mergeEntities(from: from, into: into, port: port)
        }
    }

    func deleteEntity(id: String) {
        performRepair { port in
            try await ThreadGraphAdmin.deleteEntity(id: id, port: port)
        }
    }

    func setEntityKind(id: String, kind: String) {
        performRepair { port in
            try await ThreadGraphAdmin.setEntityKind(id: id, kind: kind, port: port)
        }
    }

    func deleteRelationship(id: String) {
        performRepair { port in
            try await ThreadGraphAdmin.deleteRelationship(id: id, port: port)
        }
    }

    /// Repair that needs an owner (DatabaseRequest envelope). 120 s deadline (LLM extractor).
    func reextractDocument(id: String) {
        guard !isMutating else { return }
        isMutating = true
        Task { [weak self] in
            guard let self else { return }
            let (owner, notice) = await self.threadReadPreflight()
            guard let owner else {
                self.mutationNotice = notice
                self.isMutating = false
                return
            }
            await self.finishRepair { port in
                try await ThreadGraphAdmin.reextractDocument(
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
            let result = try await operation(threadHTTPPort)
            mutationNotice = Self.mutationLine(result)
        } catch {
            mutationNotice = error.localizedDescription
        }
        isMutating = false
        // Graph on screen is pre-mutation; re-ask rather than trusting the response shape.
        if let shape = lastGraphRequest { runGraphQuery(shape) }
    }

    // MARK: - Guards

    /// Shared Thread gRPC preflight. Failure is a named notice, never an unexplained empty.
    private func threadReadPreflight() async -> (owner: String?, notice: String?) {
        guard isThreadHealthy else {
            return (nil, "Thread isn't running — start it from the Servers sheet.")
        }
        guard let owner = await MaryRuntime.sewnSession.userID else {
            return (nil, "Sign in to Sewn first — Thread holds documents per owner.")
        }
        return (owner, nil)
    }

    // MARK: - The pure core

    struct Built: Equatable {
        var fleetHeader: ThreadFleetHeader?
        var nodeRows: [ThreadNodeRow] = []
        var diskRows: [ThreadDiskRow] = []
        var diskSummary: ThreadDiskSummary?
        var nodesNotice: String?
        var familyChips: [ThreadFamilyChip] = []
        var laneSections: [ThreadLaneSection] = []
        var libraryHasMore = false
        var graph: GraphQueryResult?
        var retrievalRows: [ThreadRetrievalTurnRow] = []
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
        // Config beats the node-id file (same rule as the server). Scanner verdict leads.
        let liveID = inputs.disk?.liveNodeID
            ?? ThreadNodeIdentity.canonical(inputs.configuredNodeID)

        if let fleet = inputs.fleet {
            built.fleetHeader = ThreadFleetHeader(
                mothershipID: fleet.mothershipID,
                totalDocumentCount: fleet.totalDocumentCount,
                totalGroupCount: fleet.totalGroupCount,
                enabled: fleet.enabled,
                nodeCount: fleet.nodes.count)
            built.nodeRows = fleet.nodes.map { node in
                ThreadNodeRow(
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
            // Scanner already ordered live-first, newest orphan next.
            built.diskRows = disk.nodes.map { node in
                var layers: [String] = []
                if node.hasTable { layers.append("table") }
                if node.hasGraph { layers.append("graph") }
                if node.hasRegistry { layers.append("registry") }
                return ThreadDiskRow(
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
            built.diskSummary = ThreadDiskSummary(
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
        let rows = inputs.groups.map { group -> ThreadGroupRow in
            let classification = ThreadAddressClassifier.classifyGroup(id: group.id)
            return ThreadGroupRow(
                id: group.id,
                label: group.label.isEmpty ? group.id : group.label,
                documentCount: group.documents.count,
                family: classification.family,
                familyTitle: familyTitle(classification.family),
                lane: classification.lane,
                isSewnOwned: classification.isSewnOwned,
                documents: group.documents.map { document in
                    let family = ThreadAddressClassifier.classifyDocument(id: document.id).family
                    return ThreadDocumentRow(
                        id: document.id,
                        name: document.name.isEmpty ? document.id : document.name,
                        createdAt: documentDate(fromCreatedAt: document.createdAt),
                        family: family,
                        familyTitle: familyTitle(family))
                })
        }

        // One chip per family present, in enum order — not a roster of empties.
        built.familyChips = ThreadAddressFamily.allCases.compactMap { family in
            let count = rows.filter { $0.family == family }.count
            guard count > 0 else { return nil }
            return ThreadFamilyChip(family: family, title: familyTitle(family), count: count)
        }

        // Lane buckets, fixed order. Sewn-owned is not a Mary lane; unknown stays unknown.
        let sections: [(id: String, title: String, subtitle: String, groups: [ThreadGroupRow])] = [
            ("ability", "Ability lane",
             "Behavioral codec for the activated discipline — input and output of each sealed turn.",
             rows.filter { $0.lane == .ability }),
            ("personal", "Personal lane",
             "Interactions that produced an Ability deposit, plus project units and style.",
             rows.filter { $0.lane == .personal }),
            ("sewn", "Sewn's own",
             "Written by the Sewn server on its own; never Mary's to rewrite.",
             rows.filter { $0.isSewnOwned }),
            ("unknown", "Unrecognized",
             "No minter Mary knows about — foreign or future addresses.",
             rows.filter { $0.family == .unknown }),
        ]
        built.laneSections = sections
            .filter { !$0.groups.isEmpty }
            .map { ThreadLaneSection(id: $0.id, title: $0.title, subtitle: $0.subtitle, groups: $0.groups) }

        built.libraryHasMore = inputs.hasMoreGroups
    }

    /// Chip filter: lane (`ability`/`personal`) or family raw value. Nil = everything.
    nonisolated static func sections(
        _ sections: [ThreadLaneSection], matching filter: String?
    ) -> [ThreadLaneSection] {
        guard let filter, !filter.isEmpty else { return sections }
        if sections.contains(where: { $0.id == filter }) {
            return sections.filter { $0.id == filter }
        }
        guard let family = ThreadAddressFamily(rawValue: filter) else { return sections }
        return sections.compactMap { section in
            let groups = section.groups.filter { $0.family == family }
            guard !groups.isEmpty else { return nil }
            var filtered = section
            filtered.groups = groups
            return filtered
        }
    }

    nonisolated static func familyTitle(_ family: ThreadAddressFamily) -> String {
        switch family {
        case .abilityGroup: return "Ability"
        case .scopeGroup: return "Scope"
        case .behaviorInteraction: return "Interactions"
        case .styleGroup: return "Style"
        case .routingGroup: return "Routing"
        case .applicationHabitGroup: return "Application habits"
        case .sewnMemory: return "Memory"
        case .sewnResonance: return "Resonance"
        case .abilityDocument: return "Ability document"
        case .abilitySchemaManifest: return "Schema manifest"
        case .abilitySchema: return "Ability schema"
        case .projectSchema: return "Project schema"
        case .stateSnapshot: return "State snapshot"
        case .skillRecord: return "Skill record"
        case .unitManifest: return "Unit manifest"
        case .unitCard: return "Unit card"
        case .styleProfile: return "Style profile"
        case .behaviorEpisode: return "Behavioral codec"
        case .behaviorInteractionDocument: return "Interaction"
        case .routingHabit: return "Routing habit"
        case .applicationHabitLedger: return "Application habit ledger"
        case .unknown: return "Unknown"
        }
    }

    // MARK: Graph helpers

    /// Hops never 0 (wire maps 0→1). Seed is free text, not exact-name (30 s semantic match).
    nonisolated static func shapeGraphRequest(
        seed: String, kind: String?, hops: Int, includeDocuments: Bool
    ) -> ThreadGraphRequestShape {
        ThreadGraphRequestShape(
            query: seed.trimmingCharacters(in: .whitespacesAndNewlines),
            kinds: kind.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
            hops: min(3, max(1, hops)),
            limit: 20,
            includeDocuments: includeDocuments)
    }

    /// Edge endpoints may be pruned by `limit` — id is the fallback, never force-unwrap.
    nonisolated static func entityName(_ id: String, in result: GraphQueryResult?) -> String {
        result?.entities.first { $0.id == id }?.name ?? id
    }

    /// `success: false` + nil surviving id = Thread "no such entity" (data, not transport).
    nonisolated static func mutationLine(_ result: MutationResult) -> String {
        guard result.success else {
            return result.survivingID == nil
                ? "No such entity — the graph may have changed since this query."
                : "Thread refused the mutation."
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

    nonisolated static func retrievalRows(_ inputs: Inputs) -> [ThreadRetrievalTurnRow] {
        // Newest route wins a duplicated exchange id (both buffers newest-first).
        var routesByExchange: [UUID: AmbientTraceRecord] = [:]
        for record in inputs.routes {
            guard let exchangeID = record.exchangeID,
                  routesByExchange[exchangeID] == nil else { continue }
            routesByExchange[exchangeID] = record
        }

        var rows: [ThreadRetrievalTurnRow] = []
        var joined: Set<UUID> = []
        for capture in inputs.retrieval {
            let route = routesByExchange[capture.exchangeID]
            if route != nil { joined.insert(capture.exchangeID) }
            rows.append(turnRow(capture: capture, route: route))
        }
        // Route with no ledger row is still a turn ("why no retrieval?").
        for record in inputs.routes {
            if let exchangeID = record.exchangeID, joined.contains(exchangeID) { continue }
            rows.append(turnRow(capture: nil, route: record))
        }
        rows.sort { $0.date > $1.date }
        return Array(rows.prefix(120))
    }

    nonisolated private static func turnRow(
        capture: ThreadRetrievalCapture?, route: AmbientTraceRecord?
    ) -> ThreadRetrievalTurnRow {
        let plan = route?.route.gate.memory
        let requests = (capture?.requests ?? []).map { request -> ThreadRetrievalRequestRow in
            ThreadRetrievalRequestRow(
                id: request.id,
                transport: request.transport,
                aggregate: request.aggregate,
                groups: request.groups.map { group in
                    let family = ThreadAddressClassifier.classifyGroup(id: group.id).family
                    return ThreadScopeGroupTag(
                        id: group.id,
                        label: group.label,
                        family: family,
                        familyTitle: familyTitle(family))
                },
                relationshipHints: request.relationshipHints,
                isAnswered: capture?.contribution != nil
                    && capture?.contributionRequestID == request.id)
        }

        // Partial rows carry named states — never blank, never dropped.
        var states: [String] = []
        if route == nil {
            states.append("no route row for this exchange")
        } else if capture == nil && route?.exchangeID == nil {
            states.append("recorded before the retrieval join — no exchange id")
        }
        if capture?.requests.isEmpty ?? true {
            states.append("no retrieval asked")
        }

        return ThreadRetrievalTurnRow(
            // One of the pair is always present; literal keeps the pure core deterministic.
            id: capture?.exchangeID.uuidString ?? route.map { $0.id.uuidString } ?? "unjoined",
            date: capture?.date ?? route?.date ?? Date.distantPast,
            utterance: route?.utterance,
            routeLine: route.map {
                "\($0.route.intent.rawValue) · \($0.route.decidedBy.rawValue) · \($0.route.rankingMode.rawValue)"
            },
            plan: plan.map { plan in
                ThreadMemoryPlanRow(
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

    /// Pure derivations over one turn's plan, scope, contribution, prompt spend. Never stored.
    nonisolated static func retrievalWarnings(
        plan: ThreadMemoryPlan?,
        requests: [ThreadSewnRequestCapture],
        contribution: SewnContributionTrace?,
        ambient: [AmbientInjectionTrace],
        promptSpend: [PromptSpendTrace]
    ) -> [ThreadRetrievalWarning] {
        var warnings: [ThreadRetrievalWarning] = []
        _ = plan
        let sewnRequests = requests.filter { $0.transport != .grpc }
        let grpcRequests = requests.filter { $0.transport == .grpc }
        let sewnFamilies = Set(sewnRequests.flatMap { request in
            request.groups.map { ThreadAddressClassifier.classifyGroup(id: $0.id).family }
        })

        if sewnFamilies.contains(.abilityGroup) {
            warnings.append(.init(
                kind: .planScopeMismatch,
                message: "Sewn chat was sent an Ability Thread group. Spoken retrieval is Personal interactions only."))
        }

        if grpcRequests.contains(where: { request in
            request.groups.contains { ThreadAddressClassifier.classifyGroup(id: $0.id).family == .abilityGroup }
        }) {
            warnings.append(.init(
                kind: .planScopeMismatch,
                message: "Ability codec was searched on a turn. Ability Thread is training storage, not spoken retrieval."))
        }

        if !sewnRequests.isEmpty, contribution == nil {
            warnings.append(.init(
                kind: .askedNothingBack,
                message: "Asked, nothing back — \(sewnRequests.count) Sewn request\(sewnRequests.count == 1 ? "" : "s") went out and no contribution returned."))
        }

        // Counts cannot tell demotion from a by-design mention. Message claims a full budget, never a drop.
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

    /// Locale-stable — rows are Equatable-diffed; `ByteCountFormatter` is not.
    nonisolated static func byteLine(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [(1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB")]
        for (size, suffix) in units where bytes >= size {
            return String(format: "%.1f %@", Double(bytes) / Double(size), suffix)
        }
        return "\(bytes) B"
    }

    /// Coarse age (not AmbientAge's 30-day fact scale). Sub-minute is one form so 1 Hz diff stays quiet.
    nonisolated static func ageLine(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "moments" }
        if seconds < 60 { return "under a minute" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// Thread `createdAt` is Unix seconds; zero = unstamped. Milliseconds magnitudes are decayed.
    nonisolated static func documentDate(fromCreatedAt createdAt: Int64) -> Date? {
        guard createdAt > 0 else { return nil }
        if createdAt > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000)
        }
        return Date(timeIntervalSince1970: TimeInterval(createdAt))
    }
}
