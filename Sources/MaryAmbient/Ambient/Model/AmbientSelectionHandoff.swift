//
//  AmbientSelectionHandoff.swift
//  MaryBrain
//
//  WHAT: A direct highlight is an interaction packet, not a document snapshot.
//  IN:   source-owned selection ability
//  OUT:  AmbientContextStore.recordSelection
//  PIN:  Survives the source yielding focus to Mary. Plugins enrich; they must not replace.
//

import MaryFoundation
import CryptoKit
import Foundation

/// How the source-selection ability reached the source application. The channel is
/// diagnostic provenance. It never selects a workspace or changes routing.
public enum AmbientSelectionCaptureChannel: String, Sendable, Equatable, Codable {
    /// The source application's AX selection-change notification named the
    /// element that changed.
    case accessibilityNotification
    /// The source application was yielding focus, so its registered selection
    /// ability captured the still-owned selection immediately.
    case applicationHandoff
    /// A source-owned watcher sampled an app whose AX implementation does not
    /// publish selection notifications.
    case sourcePoll
    /// An application adapter read the selection together with its document
    /// identity through one application-owned transaction (for example,
    /// Xcode's path + range + buffer AppleScript read).
    case applicationScripting

}

/// How directly Accessibility identified the element that supplied selected
/// text. This is evidence arbitration only; it never changes application scope
/// or decides what a request means.
public enum AmbientSelectionSourceEvidence: String, Sendable, Equatable, Codable {
    /// The application itself returned the value, document, and range in one
    /// read. This is stronger than an AX element identity because it proves
    /// the workspace/document scope as well as the selected value.
    case documentAtomic
    /// The source application itself materialized its current selection for a command targeted
    /// to its verified process.
    case targetedApplication
    /// The application's focused element, or an AX observer callback naming
    /// the element, supplied the text.
    case exactElement
    /// A bounded, positive-evidence search found one unambiguous descendant
    /// because the app focused a canvas/container instead of its text leaf.
    case discoveredDescendant

    public var rank: Int {
        switch self {
        case .discoveredDescendant: return 0
        case .targetedApplication, .exactElement: return 1
        case .documentAtomic: return 2
        }
    }

    public var isExact: Bool { rank >= Self.exactElement.rank }
}

/// Where the selected payload's characters came from when the source element proved a range
/// but could not return its value.
public enum AmbientSelectionPayloadRecovery: String, Sendable, Equatable, Codable {
    /// Pages returned document identity and body at the request boundary; the
    /// adapter sliced the unchanged AX range from that live body.
    case applicationBodyRange
    /// An opted-in source adapter issued Copy directly to its lifecycle- verified process,
    /// observed a newly-written nonempty plain-text value, and restored the user's pasteboard.
    case applicationCopy
}

/// Whether Accessibility says the source text surface can be changed. Highlighting is
/// always useful as a reference.
public enum AmbientSelectionEditability: String, Sendable, Equatable, Codable {
    case editable
    case readOnly
    case unknown
}

/// Context a plugin has independently verified for an existing source packet.
/// It may add document identity and a validated body range, but it never
/// changes the selected text, source process, surface, or capture time.
public struct AmbientSelectionEnrichment: Sendable, Equatable {
    /// A more specific scope independently proven for this exact interaction.
    /// `AmbientContextStore` merges it only when its application/process/
    /// surface identity agrees with the raw source packet.
    public var scope: SourceScope?
    public var subject: String?
    public var surroundingText: String?
    /// Bounds in the plugin document's own character coordinate system. They
    /// are never raw AX UTF-16 offsets; `range` keeps those source-local
    /// coordinates separately.
    public var documentBounds: Range<Int>?
    public var documentTotal: Int?
    public var documentTypedRange: TypedRange?

    public init(
        scope: SourceScope? = nil,
        subject: String? = nil,
        surroundingText: String? = nil,
        documentBounds: Range<Int>? = nil,
        documentTotal: Int? = nil,
        documentTypedRange: TypedRange? = nil
    ) {
        self.scope = scope
        self.subject = subject
        self.surroundingText = surroundingText
        self.documentBounds = documentBounds
        self.documentTotal = documentTotal
        self.documentTypedRange = documentTypedRange
    }
}

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

/// The immutable selection snapshot bound to one brain turn. A task-local scope
/// deliberately distinguishes "this turn began with no selection" from "this code is not
/// running inside a turn." Without that distinction, a highlight that arrives.
public struct AmbientSelectionTurnSnapshot: Sendable, Equatable {
    public let handoff: AmbientSelectionHandoff?

    public init(handoff: AmbientSelectionHandoff?) {
        self.handoff = handoff
    }

    /// An explicit scoped absence. This is intentionally distinct from an absent TaskLocal
    /// value: the latter means "not running inside a frozen turn" and lets readers consult the
    /// process-wide pending handoff.
    public static let empty = AmbientSelectionTurnSnapshot(handoff: nil)
}

/// Turn-local selection identity. Claiming a handoff removes it from global
/// ambient state, so only code running inside this scope sees that exact
/// highlight. A genuinely new source selection may then arm the next turn.
public enum AmbientSelectionTurnContext {
    @TaskLocal public static var snapshot: AmbientSelectionTurnSnapshot?
}
