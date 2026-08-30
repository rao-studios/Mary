//
//  ValueEnvelope.swift
//  MaryFoundation
//
//  WHAT: Schema-typed payload plus provenance. Raw values stay inside the envelope.
//  IN:   Skills / adapters → this carrier.
//  OUT:  ValueEnvelopeValidator, route traces, receipts (`payloadDigest`).
//

import CryptoKit
import Foundation

/// Origin metadata. Parent ids form a data-flow graph without logging payloads.
public struct ValueProvenance: Codable, Hashable, Sendable {
    public var adapterID: AdapterID?
    public var operation: String?
    public var interactionID: InteractionID?
    public var perceptionID: PerceptionID?
    public var parentValueIDs: [UUID]

    public init(
        adapterID: AdapterID? = nil,
        operation: String? = nil,
        interactionID: InteractionID? = nil,
        perceptionID: PerceptionID? = nil,
        parentValueIDs: [UUID] = []
    ) {
        self.adapterID = adapterID
        self.operation = operation
        self.interactionID = interactionID
        self.perceptionID = perceptionID
        self.parentValueIDs = parentValueIDs
    }
}

/// Sole runtime carrier for schema-typed data.
public struct ValueEnvelope: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var typeID: ValueTypeID
    public var schemaVersion: SemanticVersion
    public var value: MaryValue
    public var scope: SourceScope
    public var provenance: ValueProvenance
    public var privacy: DataPrivacyClass
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        typeID: ValueTypeID,
        schemaVersion: SemanticVersion = "1.0.0",
        value: MaryValue,
        scope: SourceScope = .init(),
        provenance: ValueProvenance = .init(),
        privacy: DataPrivacyClass = .private,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.typeID = typeID
        self.schemaVersion = schemaVersion
        self.value = value
        self.scope = scope
        self.provenance = provenance
        self.privacy = privacy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var payloadDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        guard now >= createdAt else { return false }
        return expiresAt.map { now <= $0 } ?? true
    }
}

public struct ValueValidationIssue: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var id: String { "\(path):\(message)" }
}

public struct ValueEnvelopeValidation: Codable, Hashable, Sendable {
    public var issues: [ValueValidationIssue]
    public var isValid: Bool { issues.isEmpty }

    public init(issues: [ValueValidationIssue] = []) {
        self.issues = issues
    }
}
