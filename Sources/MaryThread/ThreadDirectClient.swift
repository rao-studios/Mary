//
//  ThreadDirectClient.swift
//  MaryThread
//
//  WHAT: One-shot gRPC against the local Thread direct server (:9090).
//  OUT:  ThreadQuery / ThreadLibrary / ThreadGraph. Writes elsewhere ride Sewn or HTTP.
//  PIN:  Fresh plaintext HTTP/2 per call — sparse calls; user may restart from Servers.
//

import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor ThreadDirectClient {
    private let host: String
    private let port: Int

    public init(host: String = "127.0.0.1", port: Int = 9090) {
        self.host = host
        self.port = port
    }

    // MARK: - Writes

    /// Deposits documents into the thread (ThreadQuery.Index). Returns the
    /// indexed count. Thread responds before graph enrichment runs, so this is
    /// fast even when LLM extraction is enabled.
    @discardableResult
    public func deposit(
        _ items: [DepositItem],
        ownerID: String,
        groupID: String,
        groupLabel: String,
        scope: String = "personal"
    ) async throws -> Int {
        let request = ThreadProtoMap.indexRequest(
            items: items, ownerID: ownerID, groupID: groupID,
            groupLabel: groupLabel, scope: scope)
        return try await withQueryStub(timeout: .seconds(20)) { stub, options in
            let response = try await stub.index(request, options: options)
            return Int(response.indexedCount)
        }
    }

    /// Removes documents by id (ThreadQuery.Remove). Returns the removed count.
    @discardableResult
    public func remove(documentIDs: [String], ownerID: String) async throws -> Int {
        let request = ThreadProtoMap.removeRequest(documentIDs: documentIDs, ownerID: ownerID)
        return try await withQueryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.remove(request, options: options)
            return Int(response.removedCount)
        }
    }

    /// Clear every document for ownerID (empty id list = wipe). Node identity stays.
    @discardableResult
    public func clearOwner(ownerID: String) async throws -> Int {
        try await remove(documentIDs: [], ownerID: ownerID)
    }

    /// Clears just the owner's groups whose id begins with `prefix` by
    /// enumerating the library and removing their documents.
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

    /// Semantic search over the owner's documents. Thread embeds `query`
    /// server-side (Mistral API or MLX depending on its launch flags).
    public func search(
        query: String,
        ownerID: String,
        scope: String = "personal",
        topK: Int = 5,
        groupIDs: [String] = [],
        timeout: Duration = .seconds(30)
    ) async throws -> [PartitionHit] {
        let request = ThreadProtoMap.searchRequest(
            query: query, ownerID: ownerID, scope: scope,
            topK: topK, groupIDs: groupIDs)
        return try await withQueryStub(timeout: timeout) { stub, options in
            let response = try await stub.search(request, options: options)
            return response.results.map(ThreadProtoMap.hit(from:))
        }
    }

    /// Pages the owner's library groups.
    public func library(
        ownerID: String,
        limit: Int = 50,
        afterID: String = ""
    ) async throws -> (groups: [GroupSummary], hasMore: Bool) {
        let request = ThreadProtoMap.libraryRequest(
            ownerID: ownerID, limit: limit, afterID: afterID, documentIDs: [])
        return try await withLibraryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.library(request, options: options)
            return (response.groups.map(ThreadProtoMap.group(from:)), response.hasMore_p)
        }
    }

    /// Full document by id. Unknown ids omitted; old Thread may throw UNIMPLEMENTED.
    public func documents(ids: [String], ownerID: String) async throws -> [DocumentContent] {
        let request = ThreadProtoMap.documentsRequest(ids: ids, ownerID: ownerID)
        return try await withLibraryStub(timeout: .seconds(30)) { stub, options in
            let response = try await stub.documents(request, options: options)
            return response.documents.map(ThreadProtoMap.documentContent(from:))
        }
    }

    /// Paged full-document export (ThreadLibrary.ExportCorpus). Training must
    /// not reconstruct pairs from search snippets.
    public func exportCorpus(
        ownerID: String,
        groupIDs: [String] = [],
        documentIDPrefix: String = "mary-behavior-",
        afterID: String = "",
        limit: Int = 200
    ) async throws -> (documents: [DocumentContent], hasMore: Bool) {
        let request = ThreadProtoMap.exportCorpusRequest(
            ownerID: ownerID, groupIDs: groupIDs,
            documentIDPrefix: documentIDPrefix, afterID: afterID, limit: limit)
        return try await withLibraryStub(timeout: .seconds(60)) { stub, options in
            let response = try await stub.exportCorpus(request, options: options)
            return (
                response.documents.map(ThreadProtoMap.documentContent(from:)),
                response.hasMore_p)
        }
    }

    /// Groups containing any of the given documents — the inspector's
    /// document-id → group-label lookup.
    public func groups(
        containing documentIDs: [String],
        ownerID: String
    ) async throws -> [GroupSummary] {
        let request = ThreadProtoMap.libraryRequest(
            ownerID: ownerID, limit: 0, afterID: "", documentIDs: documentIDs)
        return try await withLibraryStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.library(request, options: options)
            return response.groups.map(ThreadProtoMap.group(from:))
        }
    }

    /// Whole-graph counts + top entities by mention, via ThreadGraph.Query
    /// browse mode (empty entity and query).
    public func graphStats(ownerID: String, limit: Int = 8) async throws -> GraphStats {
        let request = ThreadProtoMap.graphBrowseRequest(ownerID: ownerID, limit: limit)
        return try await withGraphStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.query(request, options: options)
            return ThreadProtoMap.stats(from: response)
        }
    }

    /// Graph around a seed. Empty entity+query = browse. hops clamped 1…3; limit 0 → 20.
    public func graphQuery(
        entity: String = "",
        query: String = "",
        kinds: [String] = [],
        hops: Int = 1,
        limit: Int = 20,
        includeDocuments: Bool = true,
        ownerID: String
    ) async throws -> GraphQueryResult {
        let request = ThreadProtoMap.graphQueryRequest(
            entity: entity, query: query, kinds: kinds, hops: hops,
            limit: limit, includeDocuments: includeDocuments, ownerID: ownerID)
        return try await withGraphStub(timeout: .seconds(30)) { stub, options in
            let response = try await stub.query(request, options: options)
            return ThreadProtoMap.graphResult(from: response)
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
            Thread_V1_ThreadQuery.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Thread_V1_ThreadQuery.Client(wrapping: client), options)
        }
    }

    private func withLibraryStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Thread_V1_ThreadLibrary.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Thread_V1_ThreadLibrary.Client(wrapping: client), options)
        }
    }

    private func withGraphStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Thread_V1_ThreadGraph.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Thread_V1_ThreadGraph.Client(wrapping: client), options)
        }
    }
}

// MARK: - Facade ↔ proto mapping (pure, unit-tested)

enum ThreadProtoMap {
    static func indexRequest(
        items: [DepositItem], ownerID: String, groupID: String,
        groupLabel: String, scope: String
    ) -> Thread_V1_ThreadIndexRequest {
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = ownerID
        request.groupID = groupID
        request.groupLabel = groupLabel
        request.scope = scope
        request.items = items.map { item in
            var out = Thread_V1_ThreadIndexItem()
            out.documentID = item.documentID
            out.texts = item.texts
            out.tags = item.tags
            out.name = item.name
            out.metadata = item.metadata
            out.mediaType = item.mediaType
            out.entities = item.entities.map { entity in
                var e = Thread_V1_ThreadGraphEntityIn()
                e.name = entity.name
                e.kind = entity.kind
                return e
            }
            out.relationships = item.relationships.map { relation in
                var r = Thread_V1_ThreadGraphRelationIn()
                r.subject = relation.subject
                r.predicate = relation.predicate
                r.object = relation.object
                return r
            }
            return out
        }
        return request
    }

    static func removeRequest(documentIDs: [String], ownerID: String) -> Thread_V1_ThreadRemoveRequest {
        var request = Thread_V1_ThreadRemoveRequest()
        request.ownerID = ownerID
        request.documentIds = documentIDs
        return request
    }

    static func searchRequest(
        query: String, ownerID: String, scope: String, topK: Int, groupIDs: [String]
    ) -> Thread_V1_ThreadSearchRequest {
        var request = Thread_V1_ThreadSearchRequest()
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
    ) -> Thread_V1_ThreadLibraryRequest {
        var request = Thread_V1_ThreadLibraryRequest()
        request.ownerID = ownerID
        request.limit = Int32(limit)
        request.afterID = afterID
        request.documentIds = documentIDs
        request.includeAvailable = true
        return request
    }

    static func documentsRequest(ids: [String], ownerID: String) -> Thread_V1_ThreadDocumentsRequest {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = ownerID
        request.documentIds = ids
        return request
    }

    static func exportCorpusRequest(
        ownerID: String, groupIDs: [String],
        documentIDPrefix: String, afterID: String, limit: Int
    ) -> Thread_V1_ThreadExportCorpusRequest {
        var request = Thread_V1_ThreadExportCorpusRequest()
        request.ownerID = ownerID
        request.groupIds = groupIDs
        request.documentIDPrefix = documentIDPrefix
        request.afterID = afterID
        request.limit = Int32(limit)
        return request
    }

    static func documentContent(from proto: Thread_V1_ThreadDocumentContent) -> DocumentContent {
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
    ) -> Thread_V1_ThreadGraphQueryRequest {
        var request = Thread_V1_ThreadGraphQueryRequest()
        request.ownerID = ownerID
        request.entity = entity
        request.query = query
        request.kinds = kinds
        request.hops = Int32(hops)
        request.limit = Int32(limit)
        request.includeDocuments = includeDocuments
        return request
    }

    /// Browse mode = zero-seed graphQueryRequest. Explicit defaults keep proto3 bytes identical.
    static func graphBrowseRequest(ownerID: String, limit: Int) -> Thread_V1_ThreadGraphQueryRequest {
        graphQueryRequest(
            entity: "", query: "", kinds: [], hops: 0,
            limit: limit, includeDocuments: false, ownerID: ownerID)
    }

    static func hit(from result: Thread_V1_ThreadPartitionResult) -> PartitionHit {
        PartitionHit(
            threadID: result.threadID,
            partitionID: result.partitionID,
            documentID: result.documentID,
            ownerID: result.ownerID,
            text: result.text,
            score: result.score
        )
    }

    static func group(from group: Thread_V1_ThreadGroup) -> GroupSummary {
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

    static func graphResult(from response: Thread_V1_ThreadGraphQueryResponse) -> GraphQueryResult {
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

    static func stats(from response: Thread_V1_ThreadGraphQueryResponse) -> GraphStats {
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
