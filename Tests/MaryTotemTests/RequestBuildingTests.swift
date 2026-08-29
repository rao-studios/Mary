//
//  RequestBuildingTests.swift
//  MaryTotemTests
//
//  Facade ↔ proto mapping, no live server. The wire contract lives in the
//  shared Conduit checkout; these tests pin how Mary's value types land on
//  it — especially the graph payload, where a mapping slip silently costs
//  entities/relationships.
//

import Conduit
import XCTest
@testable import MaryTotem

final class RequestBuildingTests: XCTestCase {

    func testIndexRequestMapsAllFields() {
        let items = [
            DepositItem(
                documentID: "mary-tool-1",
                texts: ["read_file — for: show me Greeter\ncontents…"],
                tags: ["read_file", "mary"],
                name: "read_file result",
                metadata: Data("origin=mary".utf8),
                entities: [
                    TotemEntityIn(name: "ritesh", kind: "person"),
                    TotemEntityIn(name: "mary", kind: "project"),
                ],
                relationships: [
                    TotemRelationIn(subject: "ritesh", predicate: "works on", object: "mary")
                ]
            )
        ]
        let request = TotemProtoMap.indexRequest(
            items: items, ownerID: "owner-1", groupID: "mary-behavior-interaction-owner-1",
            groupLabel: "Interactions", scope: "personal")

        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertEqual(request.groupID, "mary-behavior-interaction-owner-1")
        XCTAssertEqual(request.groupLabel, "Interactions")
        XCTAssertEqual(request.scope, "personal")
        XCTAssertEqual(request.items.count, 1)

        let item = request.items[0]
        XCTAssertEqual(item.documentID, "mary-tool-1")
        XCTAssertEqual(item.texts.count, 1)
        XCTAssertEqual(item.tags, ["read_file", "mary"])
        XCTAssertEqual(item.name, "read_file result")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.metadata, Data("origin=mary".utf8))
        XCTAssertEqual(item.entities.map(\.name), ["ritesh", "mary"])
        XCTAssertEqual(item.entities.map(\.kind), ["person", "project"])
        XCTAssertEqual(item.relationships.count, 1)
        XCTAssertEqual(item.relationships[0].subject, "ritesh")
        XCTAssertEqual(item.relationships[0].predicate, "works on")
        XCTAssertEqual(item.relationships[0].object, "mary")
    }

    func testSearchRequestUsesQueryTextAndAggregate() {
        let request = TotemProtoMap.searchRequest(
            query: "what did I read", ownerID: "owner-1", scope: "personal",
            topK: 5, groupIDs: ["g1"])
        XCTAssertEqual(request.queryText, "what did I read")
        XCTAssertTrue(request.queryEmbedding.isEmpty, "Totem embeds server-side when query_embedding is empty")
        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertEqual(request.scope, "personal")
        XCTAssertEqual(request.topK, 5)
        XCTAssertEqual(request.groupIds, ["g1"])
        XCTAssertTrue(request.aggregate)
    }

    func testLibraryRequestPagination() {
        let request = TotemProtoMap.libraryRequest(
            ownerID: "owner-1", limit: 50, afterID: "cursor", documentIDs: [])
        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertEqual(request.limit, 50)
        XCTAssertEqual(request.afterID, "cursor")
        XCTAssertTrue(request.documentIds.isEmpty)
        XCTAssertTrue(request.includeAvailable)
    }

    func testLibraryRequestDocumentFilter() {
        let request = TotemProtoMap.libraryRequest(
            ownerID: "owner-1", limit: 0, afterID: "", documentIDs: ["d1", "d2"])
        XCTAssertEqual(request.documentIds, ["d1", "d2"])
        XCTAssertEqual(request.limit, 0, "0 = no limit")
    }

    func testGraphBrowseRequestLeavesEntityAndQueryEmpty() {
        let request = TotemProtoMap.graphBrowseRequest(ownerID: "owner-1", limit: 8)
        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertTrue(request.entity.isEmpty, "browse mode requires empty entity")
        XCTAssertTrue(request.query.isEmpty, "browse mode requires empty query")
        XCTAssertEqual(request.limit, 8)
        XCTAssertFalse(request.includeDocuments)
    }

    func testGraphQueryRequestMapsAllFields() {
        let request = TotemProtoMap.graphQueryRequest(
            entity: "mary", query: "voice assistant", kinds: ["project", "app"],
            hops: 2, limit: 10, includeDocuments: true, ownerID: "owner-1")
        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertEqual(request.entity, "mary")
        XCTAssertEqual(request.query, "voice assistant")
        XCTAssertEqual(request.kinds, ["project", "app"])
        XCTAssertEqual(request.hops, 2)
        XCTAssertEqual(request.limit, 10)
        XCTAssertTrue(request.includeDocuments)
    }

    func testGraphQueryRequestEmptySeedIsBrowseMode() {
        // The request graphBrowseRequest built before it delegated: ownerID
        // and limit only, every other field left at its proto3 zero value.
        var legacy = Totem_V1_TotemGraphQueryRequest()
        legacy.ownerID = "owner-1"
        legacy.limit = 8

        let browse = TotemProtoMap.graphBrowseRequest(ownerID: "owner-1", limit: 8)
        XCTAssertEqual(browse, legacy, "delegation must not change the browse request")
    }

    func testGraphResultMapsEntitiesRelationshipsDocumentsAndCounts() {
        var seed = Totem_V1_TotemGraphEntity()
        seed.id = "e1"
        seed.name = "mary"
        seed.kind = "project"
        seed.score = 0.5
        seed.mentionCount = 12
        seed.documentIds = ["d1", "d2"]
        var neighbor = Totem_V1_TotemGraphEntity()
        neighbor.id = "e2"
        neighbor.name = "ritesh"
        neighbor.kind = "person"
        neighbor.score = 0
        neighbor.mentionCount = 7
        neighbor.documentIds = ["d2"]

        var edge = Totem_V1_TotemGraphRelationship()
        edge.id = "r1"
        edge.subjectID = "e2"
        edge.predicate = "works on"
        edge.objectID = "e1"
        edge.weight = 3
        edge.documentIds = ["d2"]

        var doc = Totem_V1_TotemGraphDocument()
        doc.id = "d2"
        doc.name = "Standup notes"
        doc.ownerID = "owner-1"

        var stats = Totem_V1_TotemGraphStats()
        stats.entityCount = 40
        stats.relationshipCount = 90

        var response = Totem_V1_TotemGraphQueryResponse()
        response.entities = [seed, neighbor]
        response.relationships = [edge]
        response.documents = [doc]
        response.stats = stats

        let result = TotemProtoMap.graphResult(from: response)
        XCTAssertEqual(result.entities, [
            GraphEntity(
                id: "e1", name: "mary", kind: "project",
                score: 0.5, mentionCount: 12, documentIDs: ["d1", "d2"]),
            GraphEntity(
                id: "e2", name: "ritesh", kind: "person",
                score: 0, mentionCount: 7, documentIDs: ["d2"]),
        ])
        XCTAssertEqual(result.relationships, [
            GraphRelationship(
                id: "r1", subjectID: "e2", predicate: "works on",
                objectID: "e1", weight: 3, documentIDs: ["d2"])
        ], "subject/object are entity ids and must not swap sides")
        XCTAssertEqual(result.documents, [
            GraphDocumentRef(id: "d2", name: "Standup notes", ownerID: "owner-1")
        ])
        XCTAssertEqual(result.entityCount, 40, "whole-graph count from stats, not the returned slice")
        XCTAssertEqual(result.relationshipCount, 90)
    }

    func testDocumentsRequestMapping() {
        let request = TotemProtoMap.documentsRequest(ids: ["d1", "d2"], ownerID: "owner-1")
        XCTAssertEqual(request.ownerID, "owner-1")
        XCTAssertEqual(request.documentIds, ["d1", "d2"])
    }

    func testDocumentContentMappingAndJoin() {
        var proto = Totem_V1_TotemDocumentContent()
        proto.id = "d1"
        proto.name = "Meeting notes"
        proto.ownerID = "owner-1"
        proto.groupID = "g1"
        proto.groupLabel = "Memory"
        proto.createdAt = 42
        proto.texts = ["part one", "part two"]
        proto.mediaType = "text"

        let content = TotemProtoMap.documentContent(from: proto)
        XCTAssertEqual(content.id, "d1")
        XCTAssertEqual(content.name, "Meeting notes")
        XCTAssertEqual(content.groupLabel, "Memory")
        XCTAssertEqual(content.createdAt, 42)
        XCTAssertEqual(content.texts, ["part one", "part two"])
        XCTAssertEqual(content.content, "part one\npart two", "join preserves stored order")
    }

    func testResponseMapping() {
        var partition = Totem_V1_TotemPartitionResult()
        partition.totemID = "t"
        partition.partitionID = "p"
        partition.documentID = "d"
        partition.ownerID = "o"
        partition.text = "hello"
        partition.score = 0.5
        let hit = TotemProtoMap.hit(from: partition)
        XCTAssertEqual(hit.documentID, "d")
        XCTAssertEqual(hit.text, "hello")
        XCTAssertEqual(hit.score, 0.5)

        var doc = Totem_V1_TotemDocument()
        doc.id = "d1"
        doc.name = "Note"
        doc.createdAt = 42
        var group = Totem_V1_TotemGroup()
        group.id = "g1"
        group.label = "Memory"
        group.ownerID = "o"
        group.documents = [doc]
        group.tags = ["memory"]
        let summary = TotemProtoMap.group(from: group)
        XCTAssertEqual(summary.label, "Memory")
        XCTAssertEqual(summary.documents.map(\.id), ["d1"])
        XCTAssertEqual(summary.documents[0].createdAt, 42)

        var entity = Totem_V1_TotemGraphEntity()
        entity.id = "e1"
        entity.name = "mary"
        entity.kind = "project"
        entity.mentionCount = 3
        var response = Totem_V1_TotemGraphQueryResponse()
        response.entities = [entity]
        var stats = Totem_V1_TotemGraphStats()
        stats.entityCount = 10
        stats.relationshipCount = 4
        response.stats = stats
        let mapped = TotemProtoMap.stats(from: response)
        XCTAssertEqual(mapped.entityCount, 10)
        XCTAssertEqual(mapped.relationshipCount, 4)
        XCTAssertEqual(mapped.topEntities, [GraphTopEntity(id: "e1", name: "mary", kind: "project", mentionCount: 3)])
    }
}
