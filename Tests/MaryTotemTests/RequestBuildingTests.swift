//
//  RequestBuildingTests.swift
//  MaryTotemTests
//
//  WHAT: Mary's value types land on the Conduit graph payload.
//  OUT:  TotemProtoMap
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

}
