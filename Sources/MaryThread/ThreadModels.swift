//
//  ThreadModels.swift
//  MaryThread
//
//  WHAT: Value types the app trades with the Thread facade.
//  PIN:  Generated Thread_V1_* protos never leave this package.
//

import Foundation

/// Graph entity on a deposit. kind is free-form ("" = concept). Mary adds file|project|app|ability|skill.
public struct ThreadEntityIn: Sendable, Equatable, Codable {
    public var name: String
    public var kind: String

    public init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }
}

/// Relationship. Subject/object must match an entity name in the same item.
public struct ThreadRelationIn: Sendable, Equatable, Codable {
    public var subject: String
    public var predicate: String
    public var object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// One document going into the thread. Empty `entities` + `tags` means Thread
/// runs its own graph extraction on the texts.
public struct DepositItem: Sendable, Equatable {
    public var documentID: String
    public var texts: [String]
    public var tags: [String]
    public var name: String
    public var mediaType: String
    public var metadata: Data
    public var entities: [ThreadEntityIn]
    public var relationships: [ThreadRelationIn]

    public init(
        documentID: String,
        texts: [String],
        tags: [String] = [],
        name: String = "",
        mediaType: String = "text",
        metadata: Data = Data(),
        entities: [ThreadEntityIn] = [],
        relationships: [ThreadRelationIn] = []
    ) {
        self.documentID = documentID
        self.texts = texts
        self.tags = tags
        self.name = name
        self.mediaType = mediaType
        self.metadata = metadata
        self.entities = entities
        self.relationships = relationships
    }
}

/// One search hit (a partition of a document).
public struct PartitionHit: Sendable, Equatable {
    public var threadID: String
    public var partitionID: String
    public var documentID: String
    public var ownerID: String
    public var text: String
    public var score: Float

    public init(
        threadID: String, partitionID: String, documentID: String,
        ownerID: String, text: String, score: Float
    ) {
        self.threadID = threadID
        self.partitionID = partitionID
        self.documentID = documentID
        self.ownerID = ownerID
        self.text = text
        self.score = score
    }
}

/// Library metadata for one document. Thread has no content-by-id fetch —
/// content previews go through `search` instead.
public struct DocumentSummary: Sendable, Equatable {
    public var id: String
    public var url: String
    public var ownerID: String
    public var name: String
    public var createdAt: Int64

    public init(id: String, url: String, ownerID: String, name: String, createdAt: Int64) {
        self.id = id
        self.url = url
        self.ownerID = ownerID
        self.name = name
        self.createdAt = createdAt
    }
}

/// One library group and its documents.
public struct GroupSummary: Sendable, Equatable {
    public var id: String
    public var label: String
    public var ownerID: String
    public var documents: [DocumentSummary]
    public var access: String
    public var groupDescription: String
    public var tags: [String]

    public init(
        id: String, label: String, ownerID: String,
        documents: [DocumentSummary], access: String,
        groupDescription: String, tags: [String]
    ) {
        self.id = id
        self.label = label
        self.ownerID = ownerID
        self.documents = documents
        self.access = access
        self.groupDescription = groupDescription
        self.tags = tags
    }
}

/// Full document content fetched by id — partition texts in stored order.
public struct DocumentContent: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var ownerID: String
    public var groupID: String
    public var groupLabel: String
    public var createdAt: Int64
    public var texts: [String]
    public var mediaType: String

    /// The reassembled document body.
    public var content: String { texts.joined(separator: "\n") }

    public init(
        id: String, name: String, ownerID: String,
        groupID: String, groupLabel: String, createdAt: Int64,
        texts: [String], mediaType: String
    ) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.groupID = groupID
        self.groupLabel = groupLabel
        self.createdAt = createdAt
        self.texts = texts
        self.mediaType = mediaType
    }
}

/// A high-mention entity surfaced by graph browse mode.
public struct GraphTopEntity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var mentionCount: Int

    public init(id: String, name: String, kind: String, mentionCount: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mentionCount = mentionCount
    }
}

/// Whole-graph counts plus the most-mentioned entities.
public struct GraphStats: Sendable, Equatable {
    public var entityCount: Int
    public var relationshipCount: Int
    public var topEntities: [GraphTopEntity]

    public init(entityCount: Int, relationshipCount: Int, topEntities: [GraphTopEntity]) {
        self.entityCount = entityCount
        self.relationshipCount = relationshipCount
        self.topEntities = topEntities
    }
}

/// One entity returned by a graph query — either a seed match or a hop
/// neighbor of one.
public struct GraphEntity: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    /// Seed-match score. 0 means the entity arrived by hop expansion, not by
    /// matching the seed — the server never scores neighbors.
    public var score: Float
    public var mentionCount: Int
    public var documentIDs: [String]

    public init(
        id: String, name: String, kind: String,
        score: Float, mentionCount: Int, documentIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.score = score
        self.mentionCount = mentionCount
        self.documentIDs = documentIDs
    }
}

/// Query-side edge. subjectID/objectID are entity ids — join GraphQueryResult.entities to label.
public struct GraphRelationship: Sendable, Equatable, Identifiable {
    public var id: String
    public var subjectID: String
    public var predicate: String
    public var objectID: String
    public var weight: Int
    public var documentIDs: [String]

    public init(
        id: String, subjectID: String, predicate: String,
        objectID: String, weight: Int, documentIDs: [String]
    ) {
        self.id = id
        self.subjectID = subjectID
        self.predicate = predicate
        self.objectID = objectID
        self.weight = weight
        self.documentIDs = documentIDs
    }
}

/// A document cited by the returned entities/relationships — populated only
/// when the query asked for documents. Metadata only; bodies still go through
/// `documents(ids:)`.
public struct GraphDocumentRef: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var ownerID: String

    public init(id: String, name: String, ownerID: String) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
    }
}

/// A queried graph neighborhood. `entityCount`/`relationshipCount` are
/// WHOLE-graph totals from the response stats, not the size of the returned
/// slice — they tell the caller how much graph the query didn't show.
public struct GraphQueryResult: Sendable, Equatable {
    public var entities: [GraphEntity]
    public var relationships: [GraphRelationship]
    public var documents: [GraphDocumentRef]
    public var entityCount: Int
    public var relationshipCount: Int

    public init(
        entities: [GraphEntity], relationships: [GraphRelationship],
        documents: [GraphDocumentRef], entityCount: Int, relationshipCount: Int
    ) {
        self.entities = entities
        self.relationships = relationships
        self.documents = documents
        self.entityCount = entityCount
        self.relationshipCount = relationshipCount
    }
}
