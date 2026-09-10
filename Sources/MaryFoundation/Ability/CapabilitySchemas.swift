//
//  CapabilitySchemas.swift
//  MaryFoundation
//
//  WHAT: Capability effect, permissions, constraints.
//  IN:   `.mary` capabilities[] → AbilityPackageValidator+Schemas.
//  OUT:  SkillRequirements, AdapterManifestValidator.
//

import Foundation

public enum CapabilityEffect: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case read
    case reversibleMutation
    case mutation
    case destructive
    case externalCommunication
}

public enum PermissionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case accessibility
    case automation
    case bluetooth
    case calendar
    case contacts
    case files
    case location
    case microphone
    case network
    case notifications
    case photos
    case reminders
    case screenRecording
    case speechRecognition
}

public struct PermissionRequirement: Codable, Hashable, Sendable {
    public var kind: PermissionKind
    public var target: String?
    public var reason: String

    public init(kind: PermissionKind, target: String? = nil, reason: String) {
        self.kind = kind
        self.target = target
        self.reason = reason
    }
}

public struct CapabilityConstraint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case maximumDurationSeconds
        case maximumPayloadBytes
        case requiresFrontmostApplication
        case requiresStableDocumentIdentity
        case requiresUserConfirmation
        case requiresStage
        case sourceMustMatchTarget
        case allowedTargetClass
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct CapabilitySchema: Codable, Hashable, Sendable, Identifiable {
    public var id: CapabilityID
    public var version: SemanticVersion
    public var title: String
    public var summary: String
    public var inputType: ValueTypeID?
    public var outputType: ValueTypeID?
    public var effect: CapabilityEffect
    public var permissions: [PermissionRequirement]
    public var constraints: [CapabilityConstraint]

    public init(
        id: CapabilityID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        inputType: ValueTypeID? = nil,
        outputType: ValueTypeID? = nil,
        effect: CapabilityEffect,
        permissions: [PermissionRequirement] = [],
        constraints: [CapabilityConstraint] = []
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.inputType = inputType
        self.outputType = outputType
        self.effect = effect
        self.permissions = permissions
        self.constraints = constraints
    }
}

/// Local adapter binding. Package names it; this machine decides if it can satisfy.
public struct AdapterBindingReference: Codable, Hashable, Sendable {
    public var adapterID: AdapterID
    public var operation: String
    public var preference: Int
    public var targetClasses: [String]

    public init(
        adapterID: AdapterID,
        operation: String,
        preference: Int = 0,
        targetClasses: [String] = []
    ) {
        self.adapterID = adapterID
        self.operation = operation
        self.preference = preference
        self.targetClasses = targetClasses
    }
}
