//
//  AXSelectionReader+Models.swift
//  MaryAmbient
//
//  WHAT: Extraction / sample / completeness types for source selection.
//  IN:   AXSelectionReader.swift (split)
//  OUT:  SelectionHandoffPublisher
//

import AppKit
import ApplicationServices
import MaryFoundation
import Foundation

extension AXSelectionReader {

    public enum Extraction: String, Sendable, Equatable {
        case selectedText
        case textMarkerRange
        case characterRange
        case valueSlice
    }

    /// What's highlighted in whatever app `pid` names, right now.
    public struct Reading: Sendable, Equatable {
        public var text: String
        public var surroundingText: String? = nil
        public var role: String?
        public var resolution: PerceptionElementResolution?
        /// AX UTF-16 coordinates when the source exposed them. These are
        /// meaningful only inside the exact element that emitted the reading;
        /// callers must validate before mapping them into another body.
        public var range: Range<Int>? = nil
        public var extraction: Extraction? = nil
        /// `AXEditable` from this exact element. A readable selection is not
        /// automatically a safe keyboard-write target.
        public var editability: AmbientSelectionEditability = .unknown
        /// AX-object identity for source ordering. It is deliberately opaque:
        /// callers use it only to keep one surface's caret from clearing a
        /// selection that another surface supplied.
        public var sourceSurfaceID: UInt? = nil
        /// AX cannot request a bounded selected value, so the reader caps what
        /// it retains and states that loss explicitly on the interaction.
        public var completeness: PayloadCompleteness = .complete
        /// Digest of the uncapped AX value when it was available.
        public var valueDigest: String? = nil

        public init(
            text: String,
            surroundingText: String? = nil,
            role: String? = nil,
            resolution: PerceptionElementResolution? = nil,
            range: Range<Int>? = nil,
            extraction: Extraction? = nil,
            editability: AmbientSelectionEditability = .unknown,
            sourceSurfaceID: UInt? = nil,
            completeness: PayloadCompleteness = .complete,
            valueDigest: String? = nil
        ) {
            self.text = text
            self.surroundingText = surroundingText
            self.role = role
            self.resolution = resolution
            self.range = range
            self.extraction = extraction
            self.editability = editability
            self.sourceSurfaceID = sourceSurfaceID
            self.completeness = completeness
            self.valueDigest = valueDigest
        }
    }

    /// Empty selected text is ambiguous until its range is known. In particular, a nonempty
    /// range that cannot be hydrated is NOT a caret; treating it as one is how a real Pages
    /// highlight became document-start context.
    public enum SelectionState: Sendable, Equatable {
        case selected(Reading)
        case caret(range: Range<Int>?)
        case unreadableNonemptyRange(range: Range<Int>)
        /// A bounded descendant walk found more than one distinct source surface with positive
        /// selection evidence. This is evidence that a selection exists, but not evidence of which
        /// leaf the user meant.
        case ambiguousSelection
        case unavailable
    }

    /// A source-owned sample. `capturedAt` is deliberately taken BEFORE the
    /// AX IPC begins, so a slow poll cannot masquerade as newer evidence than
    /// an observer event that arrived while the read was in flight.
    public struct FocusedSelectionSample: Sendable, Equatable {
        public var processID: pid_t
        public var state: SelectionState
        public var capturedAt: Date
        public var sourceSurfaceID: UInt? = nil
        /// UTF-16 extent reported by the exact element that supplied the source evidence.
        public var sourceCharacterCount: Int? = nil
        public var editability: AmbientSelectionEditability = .unknown
        /// The app-named focused element is exact evidence. A bounded canvas
        /// descent is useful for reading, but is intentionally weaker because
        /// tree order does not identify the user's active text leaf.
        public var sourceEvidence: AmbientSelectionSourceEvidence = .exactElement

        public init(
            processID: pid_t,
            state: SelectionState,
            capturedAt: Date,
            sourceSurfaceID: UInt? = nil,
            sourceCharacterCount: Int? = nil,
            editability: AmbientSelectionEditability = .unknown,
            sourceEvidence: AmbientSelectionSourceEvidence = .exactElement
        ) {
            self.processID = processID
            self.state = state
            self.capturedAt = capturedAt
            self.sourceSurfaceID = sourceSurfaceID
            self.sourceCharacterCount = sourceCharacterCount
            self.editability = editability
            self.sourceEvidence = sourceEvidence
        }
    }

    /// Bounded descent, same numbers as `PagesAX` — an unbounded AX walk on a
    /// big window is a poll-loop stall waiting to happen.
    public static let maxSearchDepth = 5
    public static let maxSearchNodes = 200
    /// A tree walk is a fallback for positive selection evidence, never a reason to stall an
    /// interaction handoff behind a busy canvas.
    public static let sourceSelectionSearchBudget: TimeInterval = 0.6

    /// Defensive in-process cap after the IPC copy returns. There is no parameterized/bounded
    /// selected-text attribute to ask AX for less, so this bounds what we HOLD, not the cost of
    /// the copy itself — the same risk profile `PagesAX.selection(from:)` already accepts.
    public static let readCap = 20_000
    public static let surroundingContextRadius = 600

    /// AX tree traversal is not an interaction ordering.
    enum DiscoveredSelectionCandidate: Sendable, Equatable {
        case selected(surfaceID: UInt)
        case unreadableNonemptyRange(surfaceID: UInt)

        public var surfaceID: UInt {
            switch self {
            case .selected(let surfaceID), .unreadableNonemptyRange(let surfaceID):
                return surfaceID
            }
        }
    }

    enum DiscoveredSelectionDisposition: Sendable, Equatable {
        case selected
        case unreadableNonemptyRange
        case ambiguous
        case none
    }

    static func discoveredSelectionDisposition(
        for candidates: [DiscoveredSelectionCandidate]
    ) -> DiscoveredSelectionDisposition {
        var seen: Set<UInt> = []
        let distinct = candidates.filter { seen.insert($0.surfaceID).inserted }
        guard let first = distinct.first else { return .none }
        guard distinct.count == 1 else { return .ambiguous }
        switch first {
        case .selected:
            return .selected
        case .unreadableNonemptyRange:
            return .unreadableNonemptyRange
        }
    }

}
