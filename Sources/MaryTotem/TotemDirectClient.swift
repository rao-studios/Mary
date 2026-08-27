//
//  TotemDirectClient.swift
//  MaryTotem
//
//  One-shot gRPC calls against the local Totem node's direct server (:9090),
//  which registers only TotemQuery, TotemLibrary, and TotemGraph — TotemUpdate
//  and everything else ride Seer's mothership session or Totem's HTTP port.
//
//  Each call opens its own plaintext HTTP/2 connection (the pattern Conduit
//  itself uses for out-of-band heartbeats): Mary's calls are sparse
//  (a deposit per Skill invocation, inspector reads), so connection reuse isn't
//  worth the lifecycle bookkeeping of a held channel to a server the user can
//  restart from the Servers sheet at any time.
//

import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor TotemDirectClient {
    private let host: String
    private let port: Int

    public init(host: String = "127.0.0.1", port: Int = 9090) {
        self.host = host
        self.port = port
    }

    // MARK: - Writes

    /// Deposits documents into the totem (TotemQuery.Index). Returns the
    /// indexed count. Totem responds before graph enrichment runs, so this is
    /// fast even when LLM extraction is enabled.
    @discardableResult
    public func deposit(
        _ items: [DepositItem],
        ownerID: String,
        groupID: String,
        groupLabel: String,
        scope: String = "personal"
    ) async throws -> Int {
        let request = TotemProtoMap.indexRequest(
            items: items, ownerID: ownerID, groupID: groupID,
            groupLabel: groupLabel, scope: scope)
        return try await withQueryStub(timeout: .seconds(20)) { stub, options in
            let response = try await stub.index(request, options: options)
            return Int(response.indexedCount)
        }
    }

    /// Removes documents by id (TotemQuery.Remove). Returns the removed count.
    @discardableResult
    public func remove(documentIDs: [String], ownerID: String) async throws -> Int {
        let request = TotemProtoMap.removeRequest(documentIDs: documentIDs, ownerID: ownerID)
        return try await withQueryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.remove(request, options: options)
            return Int(response.removedCount)
        }
    }

    /// Clears EVERY document owned by `ownerID` on this node (all groups,
    /// including saved memories) — the Totem server treats an empty id list as
    /// remove-all-for-owner. The node id / on-disk DB identity is preserved;
    /// only contents go. Named to keep that "empty means wipe" intent explicit
    /// at call sites. Returns the removed count.
    @discardableResult
    public func clearOwner(ownerID: String) async throws -> Int {
        try await remove(documentIDs: [], ownerID: ownerID)
    }

    /// Clears just the owner's groups whose id begins with `prefix` (e.g.
    /// "mary-context-<owner>") by enumerating the library and removing their
    /// documents. Leaves every other group — saved memories, other apps —
    /// untouched. Returns the removed count (0 if nothing matched).
    @discardableResult
    public func clearGroups(prefix: String, ownerID: String) async throws -> Int {
        var ids: [String] = []
        var afterID = ""
        // Mary deposits into a single group today, but page defensively; the
        // cap stops an unexpected non-advancing cursor from spinning forever.
        for _ in 0..<200 {
            let page = try await library(ownerID: ownerID, afterID: afterID)
            for group in page.groups where group.id.hasPrefix(prefix) {
                ids.append(contentsOf: group.documents.map(\.id))
            }
            guard page.hasMore, let last = page.groups.last else { break }
            afterID = last.id
        }
        guard !ids.isEmpty else { return 0 }
        return try await remove(documentIDs: ids, ownerID: ownerID)
    }

    // MARK: - Reads

    /// Semantic search over the owner's documents. Totem embeds `query`
    /// server-side (Mistral API or MLX depending on its launch flags).
    public func search(
        query: String,
        ownerID: String,
        scope: String = "personal",
        topK: Int = 5,
        groupIDs: [String] = []
    ) async throws -> [PartitionHit] {
        let request = TotemProtoMap.searchRequest(
            query: query, ownerID: ownerID, scope: scope,
            topK: topK, groupIDs: groupIDs)
        return try await withQueryStub(timeout: .seconds(30)) { stub, options in
            let response = try await stub.search(request, options: options)
            return response.results.map(TotemProtoMap.hit(from:))
        }
    }

    /// Pages the owner's library groups.
    public func library(
        ownerID: String,
        limit: Int = 50,
        afterID: String = ""
    ) async throws -> (groups: [GroupSummary], hasMore: Bool) {
        let request = TotemProtoMap.libraryRequest(
            ownerID: ownerID, limit: limit, afterID: afterID, documentIDs: [])
        return try await withLibraryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.library(request, options: options)
            return (response.groups.map(TotemProtoMap.group(from:)), response.hasMore_p)
        }
    }

    /// Full document content by id (TotemLibrary.Documents) — partition texts
    /// reassembled in stored order. Inaccessible/unknown ids are omitted by
    /// the server; an old Totem binary without the RPC throws (UNIMPLEMENTED),
    /// so callers should keep a fallback.
    public func documents(ids: [String], ownerID: String) async throws -> [DocumentContent] {
        let request = TotemProtoMap.documentsRequest(ids: ids, ownerID: ownerID)
        return try await withLibraryStub(timeout: .seconds(30)) { stub, options in
            let response = try await stub.documents(request, options: options)
            return response.documents.map(TotemProtoMap.documentContent(from:))
        }
    }

    /// Groups containing any of the given documents — the inspector's
    /// document-id → group-label lookup.
    public func groups(
        containing documentIDs: [String],
        ownerID: String
    ) async throws -> [GroupSummary] {
        let request = TotemProtoMap.libraryRequest(
            ownerID: ownerID, limit: 0, afterID: "", documentIDs: documentIDs)
        return try await withLibraryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.library(request, options: options)
            return response.groups.map(TotemProtoMap.group(from:))
        }
    }

    /// Whole-graph counts + top entities by mention, via TotemGraph.Query
    /// browse mode (empty entity and query).
    public func graphStats(ownerID: String, limit: Int = 8) async throws -> GraphStats {
        let request = TotemProtoMap.graphBrowseRequest(ownerID: ownerID, limit: limit)
        return try await withGraphStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.query(request, options: options)
            return TotemProtoMap.stats(from: response)
        }
    }

    /// Traverses the entity graph around a seed (TotemGraph.Query). `entity`
    /// matches an entity by name; `query` free-text-matches server-side; both
    /// empty is browse mode (top entities by mention, same as `graphStats`).
    /// The server clamps `hops` to 1...3 and maps 0 to 1; `limit` 0 means the
    /// server default of 20. 30-second timeout matching `search`'s: a
    /// free-text query pays a server-side embedding.
    public func graphQuery(
        entity: String = "",
        query: String = "",
        kinds: [String] = [],
        hops: Int = 1,
        limit: Int = 20,
        includeDocuments: Bool = true,
        ownerID: String
    ) async throws -> GraphQueryResult {
        let request = TotemProtoMap.graphQueryRequest(
            entity: entity, query: query, kinds: kinds, hops: hops,
            limit: limit, includeDocuments: includeDocuments, ownerID: ownerID)
        return try await withGraphStub(timeout: .seconds(30)) { stub, options in
            let response = try await stub.query(request, options: options)
            return TotemProtoMap.graphResult(from: response)
        }
    }

    // MARK: - Connection plumbing

    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try .http2NIOPosix(
            target: .ipv4(host: host, port: port),
            transportSecurity: .plaintext
        )
    }

    private func withQueryStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Totem_V1_TotemQuery.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Totem_V1_TotemQuery.Client(wrapping: client), options)
        }
    }

    private func withLibraryStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Totem_V1_TotemLibrary.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Totem_V1_TotemLibrary.Client(wrapping: client), options)
        }
    }

    private func withGraphStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Totem_V1_TotemGraph.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Totem_V1_TotemGraph.Client(wrapping: client), options)
        }
    }
}

// MARK: - Facade ↔ proto mapping (pure, unit-tested)

enum TotemProtoMap {
    static func indexRequest(
        items: [DepositItem], ownerID: String, groupID: String,
        groupLabel: String, scope: String
    ) -> Totem_V1_TotemIndexRequest {
        var request = Totem_V1_TotemIndexRequest()
        request.ownerID = ownerID
        request.groupID = groupID
        request.groupLabel = groupLabel
        request.scope = scope
        request.items = items.map { item in
            var out = Totem_V1_TotemIndexItem()
            out.documentID = item.documentID
            out.texts = item.texts
            out.tags = item.tags
            out.name = item.name
            out.metadata = item.metadata
            out.mediaType = item.mediaType
            out.entities = item.entities.map { entity in
                var e = Totem_V1_TotemGraphEntityIn()
                e.name = entity.name
                e.kind = entity.kind
                return e
            }
            out.relationships = item.relationships.map { relation in
                var r = Totem_V1_TotemGraphRelationIn()
                r.subject = relation.subject
                r.predicate = relation.predicate
                r.object = relation.object
                return r
            }
            return out
        }
        return request
    }

    static func removeRequest(documentIDs: [String], ownerID: String) -> Totem_V1_TotemRemoveRequest {
        var request = Totem_V1_TotemRemoveRequest()
        request.ownerID = ownerID
        request.documentIds = documentIDs
        return request
    }

    static func searchRequest(
        query: String, ownerID: String, scope: String, topK: Int, groupIDs: [String]
    ) -> Totem_V1_TotemSearchRequest {
        var request = Totem_V1_TotemSearchRequest()
        request.queryText = query
        request.ownerID = ownerID
        request.scope = scope
        request.topK = Int32(topK)
        request.groupIds = groupIDs
        request.aggregate = true
        return request
    }

    static func libraryRequest(
        ownerID: String, limit: Int, afterID: String, documentIDs: [String]
    ) -> Totem_V1_TotemLibraryRequest {
        var request = Totem_V1_TotemLibraryRequest()
        request.ownerID = ownerID
        request.limit = Int32(limit)
        request.afterID = afterID
        request.documentIds = documentIDs
        request.includeAvailable = true
        return request
    }

    static func documentsRequest(ids: [String], ownerID: String) -> Totem_V1_TotemDocumentsRequest {
        var request = Totem_V1_TotemDocumentsRequest()
        request.ownerID = ownerID
        request.documentIds = ids
        return request
    }

    static func documentContent(from proto: Totem_V1_TotemDocumentContent) -> DocumentContent {
        DocumentContent(
            id: proto.id,
            name: proto.name,
            ownerID: proto.ownerID,
            groupID: proto.groupID,
            groupLabel: proto.groupLabel,
            createdAt: proto.createdAt,
            texts: proto.texts,
            mediaType: proto.mediaType
        )
    }

    static func graphQueryRequest(
        entity: String, query: String, kinds: [String], hops: Int,
        limit: Int, includeDocuments: Bool, ownerID: String
    ) -> Totem_V1_TotemGraphQueryRequest {
        var request = Totem_V1_TotemGraphQueryRequest()
        request.ownerID = ownerID
        request.entity = entity
        request.query = query
        request.kinds = kinds
        request.hops = Int32(hops)
        request.limit = Int32(limit)
        request.includeDocuments = includeDocuments
        return request
    }

    /// Browse mode is the zero-seed corner of `graphQueryRequest` — proto3
    /// never serializes zero-value scalars, so setting the defaults explicitly
    /// keeps the bytes identical to the ownerID+limit request `graphStats` has
    /// always sent.
    static func graphBrowseRequest(ownerID: String, limit: Int) -> Totem_V1_TotemGraphQueryRequest {
        graphQueryRequest(
            entity: "", query: "", kinds: [], hops: 0,
            limit: limit, includeDocuments: false, ownerID: ownerID)
    }

    static func hit(from result: Totem_V1_TotemPartitionResult) -> PartitionHit {
        PartitionHit(
            totemID: result.totemID,
            partitionID: result.partitionID,
            documentID: result.documentID,
            ownerID: result.ownerID,
            text: result.text,
            score: result.score
        )
    }

    static func group(from group: Totem_V1_TotemGroup) -> GroupSummary {
        GroupSummary(
            id: group.id,
            label: group.label,
            ownerID: group.ownerID,
            documents: group.documents.map { doc in
                DocumentSummary(
                    id: doc.id, url: doc.url, ownerID: doc.ownerID,
                    name: doc.name, createdAt: doc.createdAt)
            },
            access: group.access,
            groupDescription: group.groupDescription,
            tags: group.tags
        )
    }

    static func graphResult(from response: Totem_V1_TotemGraphQueryResponse) -> GraphQueryResult {
        GraphQueryResult(
            entities: response.entities.map { entity in
                GraphEntity(
                    id: entity.id, name: entity.name, kind: entity.kind,
                    score: entity.score, mentionCount: Int(entity.mentionCount),
                    documentIDs: entity.documentIds)
            },
            relationships: response.relationships.map { edge in
                GraphRelationship(
                    id: edge.id, subjectID: edge.subjectID,
                    predicate: edge.predicate, objectID: edge.objectID,
                    weight: Int(edge.weight), documentIDs: edge.documentIds)
            },
            documents: response.documents.map { doc in
                GraphDocumentRef(id: doc.id, name: doc.name, ownerID: doc.ownerID)
            },
            entityCount: Int(response.stats.entityCount),
            relationshipCount: Int(response.stats.relationshipCount)
        )
    }

    static func stats(from response: Totem_V1_TotemGraphQueryResponse) -> GraphStats {
        GraphStats(
            entityCount: Int(response.stats.entityCount),
            relationshipCount: Int(response.stats.relationshipCount),
            topEntities: response.entities.map { entity in
                GraphTopEntity(
                    id: entity.id, name: entity.name, kind: entity.kind,
                    mentionCount: Int(entity.mentionCount))
            }
        )
    }
}
