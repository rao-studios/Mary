//
//  ValueSchemas.swift
//  MaryFoundation
//
//  WHAT: Declared Value shapes, fields, privacy classes.
//  IN:   `.mary` valueTypes / Skill ports.
//  OUT:  ValueEnvelopeValidator.
//

import Foundation

public enum ValueShape: String, Codable, Hashable, Sendable, CaseIterable {
    case string
    case boolean
    case integer
    case number
    case object
    case array
    case enumeration
    case data
}

public struct ValueFieldSchema: Codable, Hashable, Sendable {
    public var name: String
    public var valueType: ValueTypeID
    public var required: Bool
    public var summary: String
    public var privacy: DataPrivacyClass

    public init(
        name: String,
        valueType: ValueTypeID,
        required: Bool = true,
        summary: String,
        privacy: DataPrivacyClass = .`private`
    ) {
        self.name = name
        self.valueType = valueType
        self.required = required
        self.summary = summary
        self.privacy = privacy
    }
}

public struct ValueTypeSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: ValueTypeID
    public var version: SemanticVersion
    public var title: String
    public var summary: String
    public var shape: ValueShape
    public var fields: [ValueFieldSchema]
    public var itemType: ValueTypeID?
    public var enumValues: [String]

    public init(
        id: ValueTypeID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        shape: ValueShape,
        fields: [ValueFieldSchema] = [],
        itemType: ValueTypeID? = nil,
        enumValues: [String] = []
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.shape = shape
        self.fields = fields
        self.itemType = itemType
        self.enumValues = enumValues
    }
}

public enum DataPrivacyClass: String, Codable, Hashable, Sendable, CaseIterable {
    /// Package definition / public schema fixture.
    case publicDefinition
    /// This machine only; not durable Totem memory.
    case `private`
    /// User content — redact diagnostics, never export.
    case sensitive
    /// Credentials and signing keys.
    case secret
}

