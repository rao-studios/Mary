import Foundation

/// Hierarchical identity for the source of an interaction or perception.
/// Device and application adapters fill only what they can prove; an absent
/// document is an honest application-scoped interaction, not an inferred one.
public struct SourceScope: Codable, Hashable, Sendable {
    public var deviceID: String?
    public var applicationID: String?
    public var processID: Int32?
    public var processEpoch: String?
    public var activationSequence: UInt64?
    public var windowID: String?
    public var workspaceID: String?
    public var projectID: String?
    public var documentID: String?
    public var surfaceID: String?

    public init(
        deviceID: String? = nil,
        applicationID: String? = nil,
        processID: Int32? = nil,
        processEpoch: String? = nil,
        activationSequence: UInt64? = nil,
        windowID: String? = nil,
        workspaceID: String? = nil,
        projectID: String? = nil,
        documentID: String? = nil,
        surfaceID: String? = nil
    ) {
        self.deviceID = deviceID
        self.applicationID = applicationID
        self.processID = processID
        self.processEpoch = processEpoch
        self.activationSequence = activationSequence
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.documentID = documentID
        self.surfaceID = surfaceID
    }

    public var resolution: SourceResolution {
        if documentID != nil { return .document }
        if workspaceID != nil || projectID != nil { return .workspace }
        if windowID != nil { return .window }
        if applicationID != nil { return .application }
        if deviceID != nil { return .device }
        return .unresolved
    }
}

public enum SourceResolution: String, Codable, Hashable, Sendable, CaseIterable {
    case unresolved
    case device
    case application
    case window
    case workspace
    case document
}

public enum CoordinateSpace: String, Codable, Hashable, Sendable, CaseIterable {
    case accessibilityUTF16
    case documentUTF16
    case unicodeScalar
    case swiftCharacter
    case lineColumn
    case screenPoint
    case spatialPoint
}

public struct TypedRange: Codable, Hashable, Sendable {
    public var lowerBound: Int
    public var upperBound: Int
    public var coordinateSpace: CoordinateSpace

    public init(lowerBound: Int, upperBound: Int, coordinateSpace: CoordinateSpace) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.coordinateSpace = coordinateSpace
    }

    public var isValid: Bool { lowerBound >= 0 && upperBound >= lowerBound }
}

public enum PayloadCompleteness: String, Codable, Hashable, Sendable, CaseIterable {
    case complete
    case truncated
    case unavailable
}

/// Privacy-safe trace reference. Raw interaction values never ride route
/// reports, Totem receipts, or exported ability packages.
public struct InteractionInstanceReference: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var schemaID: InteractionID
    public var scope: SourceScope
    public var capturedAt: Date
    public var expiresAt: Date?
    public var completeness: PayloadCompleteness
    public var valueDigest: String?

    public init(
        id: UUID,
        schemaID: InteractionID,
        scope: SourceScope,
        capturedAt: Date,
        expiresAt: Date? = nil,
        completeness: PayloadCompleteness = .complete,
        valueDigest: String? = nil
    ) {
        self.id = id
        self.schemaID = schemaID
        self.scope = scope
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.completeness = completeness
        self.valueDigest = valueDigest
    }
}
