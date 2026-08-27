//
//  SelectionHandoffPublisher.swift
//  MaryBrain
//
//  One adapter from an application's AX selection state to Mary's
//  source-owned selection contract.  Plugins supply their application and
//  optional document context; this type owns the state semantics shared by
//  Pages, TextEdit, Scrivener, and arbitrary text surfaces.
//

import Foundation

public enum SelectionHandoffPublisher {

    /// Classify and, where possible, publish source evidence. The outcome is
    /// intentionally richer than the ambient mutation result: a specialist
    /// that sees a real nonempty range must still claim its source when that
    /// text cannot be published, otherwise the generic fallback is free to
    /// read a different AX leaf from the same app.
    @discardableResult
    public static func captureOutcome(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        ambient: AmbientContextStore,
        place: AmbientRealm,
        applicationID: String,
        subject: String? = nil,
        channel: AmbientSelectionCaptureChannel,
        /// A source losing focus can report an empty transient value, whereas
        /// a source that is still frontmost at hands-free speech start has
        /// authoritatively told us there is only a caret.  The coordinator
        /// supplies this distinction; no document/focus routing is involved.
        clearCaret: Bool = false,
        receivedAt now: Date = Date()
    ) -> SelectionHandoffCoordinator.CaptureOutcome {
        switch sample.state {
        case .selected(let reading):
            let recorded = ambient.recordSelection(.init(
                world: place.world,
                application: place.application,
                applicationID: applicationID,
                processID: Int32(sample.processID),
                sourceSurfaceID: sample.sourceSurfaceID,
                text: reading.text,
                surroundingText: reading.surroundingText,
                subject: subject,
                range: reading.range,
                completeness: reading.completeness,
                valueDigest: reading.valueDigest,
                editability: sample.editability,
                capturedAt: sample.capturedAt,
                channel: channel,
                sourceEvidence: sample.sourceEvidence), at: now)
            // A duplicate, a turn tombstone, or a newer source packet can
            // correctly reject the ambient write. It is still positive source
            // evidence and therefore must suppress a generic reread.
            return recorded ? .published : .handledButUnpublishable
        case .caret:
            // A handoff happens at a focus boundary, where the focused AX
            // element can vanish or change before the callback reads it. It
            // may publish positive evidence, but an empty value there is not
            // reliable enough to erase a source packet. A live observer or
            // source-owned poll is still an explicit caret clear.
            guard channel != .applicationHandoff || clearCaret else {
                return .noEvidence
            }
            ambient.clearSelection(
                applicationID: applicationID,
                processID: Int32(sample.processID),
                sourceSurfaceID: sample.sourceSurfaceID,
                at: sample.capturedAt,
                receivedAt: now)
            return .published
        case .unreadableNonemptyRange, .ambiguousSelection:
            return .handledButUnpublishable
        case .unavailable:
            return .noEvidence
        }
    }

    /// Compatibility adapter for pollers and tests that only need to know
    /// whether an ambient mutation was applied. Handoff callbacks use
    /// `captureOutcome` so they retain unreadable/ambiguous source evidence.
    ///
    /// Publish only evidence that has an unambiguous meaning:
    ///
    /// - selected text becomes the canonical handoff;
    /// - a zero-length range is an explicit clear from that exact source;
    /// - unreadable or ambiguous positive evidence and unavailable AX data
    ///   leave a current handoff alone rather than inventing a deselection.
    @discardableResult
    public static func publish(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        ambient: AmbientContextStore,
        place: AmbientRealm,
        applicationID: String,
        subject: String? = nil,
        channel: AmbientSelectionCaptureChannel,
        /// A source losing focus can report an empty transient value, whereas
        /// a source that is still frontmost at hands-free speech start has
        /// authoritatively told us there is only a caret.  The coordinator
        /// supplies this distinction; no document/focus routing is involved.
        clearCaret: Bool = false,
        receivedAt now: Date = Date()
    ) -> Bool {
        captureOutcome(
            sample,
            ambient: ambient,
            place: place,
            applicationID: applicationID,
            subject: subject,
            channel: channel,
            clearCaret: clearCaret,
            receivedAt: now) == .published
    }
}
