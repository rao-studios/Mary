//
//  AmbientSelectionHandoff.swift
//  MaryAmbient
//
//  WHAT: A direct highlight is an interaction packet, not a document snapshot.
//  IN:   source-owned selection ability
//  OUT:  AmbientContextStore.recordSelection
//  PIN:  Survives the source yielding focus to Mary. Plugins enrich; they must not replace.
//

import MaryFoundation
import CryptoKit
import Foundation

/// The canonical, source-owned form of a highlighted piece of text. `text` deliberately
/// keeps the exact accessibility result. `AmbientFact` clips for prompt memory; a clip is
/// never allowed to become the selection's identity or a future write target.
public struct AmbientSelectionHandoff: Sendable, Equatable, Identifiable {
    public static let handoffFreshFor: TimeInterval = 30

    public var id: UUID
    public var attention: AmbientAttention
    /// The registered application whose lane this selection belongs to, when its world holds
    /// more than one.
    public var application: String?
    /// Portable, hierarchical identity for everything the source adapter can prove.
    public var scope: SourceScope
    public var applicationID: String
    public var processID: Int32

    /// WHERE this selection came from, as ONE value. `world` and `application` are two fields
    /// answering one question.
    public var place: AmbientPlace {
        application.map(AmbientPlace.application) ?? .lane(attention)
    }
    /// Best-effort fingerprint of the live AX object that supplied the interaction. It is not a
    /// durable document id; it only distinguishes simultaneous title/comment/document surfaces
    /// under one PID so one surface's caret or fallback poll cannot rewrite another's handoff.
    public var sourceSurfaceID: UInt?
    public var text: String
    public var surroundingText: String?
    public var subject: String?
    /// Bounds verified against a plugin's document body, in that body's own
    /// character coordinate system. Unlike `range`, this is safe to expose as
    /// an ambient document location alongside `documentTotal`.
    public var documentBounds: Range<Int>?
    public var documentTotal: Int?
    public var range: Range<Int>?
    /// The coordinate space of `range`. Generic AX capture is UTF-16; an
    /// application-owned adapter may instead provide document/Swift character
    /// coordinates explicitly.
    public var typedRange: TypedRange?
    /// A plugin-validated range in the document body's coordinate system.
    /// This stays separate from the source element range so one can never be
    /// mistaken for the other.
    public var documentTypedRange: TypedRange?
    /// Whether `text` is the whole source value. Truncated payloads remain
    /// discussable but cannot silently authorize an exact replacement.
    public var completeness: PayloadCompleteness
    /// SHA-256 of the complete selected value when the provider had it, or of
    /// the held value otherwise. Raw content never needs to enter diagnostics
    /// merely to correlate the interaction.
    public var valueDigest: String?
    /// The source element's mutation capability at capture time. This does
    /// not affect whether the text can be discussed; the typer revalidates it
    /// immediately before any keyboard write.
    public var editability: AmbientSelectionEditability
    public var capturedAt: Date
    public var channel: AmbientSelectionCaptureChannel
    /// Evidence strength of the element itself, independent of whether this
    /// arrived through a notification, lifecycle handoff, or source poll.
    public var sourceEvidence: AmbientSelectionSourceEvidence
    /// Optional payload recovery provenance. Nil means the source evidence
    /// itself supplied the selected characters.
    public var payloadRecovery: AmbientSelectionPayloadRecovery?

    public init(
        id: UUID = UUID(),
        attention: AmbientAttention,
        application: String? = nil,
        applicationID: String,
        processID: Int32,
        sourceSurfaceID: UInt? = nil,
        text: String,
        scope: SourceScope? = nil,
        surroundingText: String? = nil,
        subject: String? = nil,
        documentBounds: Range<Int>? = nil,
        documentTotal: Int? = nil,
        range: Range<Int>? = nil,
        typedRange: TypedRange? = nil,
        documentTypedRange: TypedRange? = nil,
        completeness: PayloadCompleteness = .complete,
        valueDigest: String? = nil,
        editability: AmbientSelectionEditability = .unknown,
        capturedAt: Date = Date(),
        channel: AmbientSelectionCaptureChannel,
        sourceEvidence: AmbientSelectionSourceEvidence? = nil,
        payloadRecovery: AmbientSelectionPayloadRecovery? = nil
    ) {
        self.id = id
        self.attention = attention
        self.application = application
        var resolvedScope = scope ?? SourceScope()
        // The long-standing initializer arguments remain the transport
        // authority during the clean schema cutover. Fill/normalize their
        // schema equivalents here so the two representations cannot disagree.
        resolvedScope.applicationID = applicationID
        resolvedScope.processID = processID
        resolvedScope.surfaceID = sourceSurfaceID.map(String.init)
        self.scope = resolvedScope
        self.applicationID = applicationID
        self.processID = processID
        self.sourceSurfaceID = sourceSurfaceID
        self.text = text
        self.surroundingText = surroundingText
        self.subject = subject
        self.documentBounds = documentBounds
        self.documentTotal = documentTotal
        self.range = range
        self.typedRange = typedRange ?? range.map {
            TypedRange(
                lowerBound: $0.lowerBound,
                upperBound: $0.upperBound,
                coordinateSpace: .accessibilityUTF16)
        }
        self.documentTypedRange = documentTypedRange ?? documentBounds.map {
            TypedRange(
                lowerBound: $0.lowerBound,
                upperBound: $0.upperBound,
                coordinateSpace: .swiftCharacter)
        }
        self.completeness = completeness
        self.valueDigest = valueDigest ?? Self.digest(text)
        self.editability = editability
        self.capturedAt = capturedAt
        self.channel = channel
        self.sourceEvidence = sourceEvidence ?? {
            switch channel {
            case .applicationScripting:
                return .documentAtomic
            case .accessibilityNotification, .applicationHandoff:
                return .exactElement
            case .sourcePoll:
                return .discoveredDescendant
            }
        }()
        self.payloadRecovery = payloadRecovery
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= Self.handoffFreshFor
    }

    public var truncated: Bool { completeness == .truncated }

    public var interactionReference: InteractionInstanceReference {
        InteractionInstanceReference(
            id: id,
            // A CODING PLACE'S SELECTION IS A DIFFERENT KIND OF THING.
            schemaID: AmbientPlace(attention: attention, application: application).focus == .coding
                ? .codeSelection : .textSelection,
            scope: scope,
            capturedAt: capturedAt,
            expiresAt: capturedAt.addingTimeInterval(Self.handoffFreshFor),
            completeness: completeness,
            valueDigest: valueDigest)
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
