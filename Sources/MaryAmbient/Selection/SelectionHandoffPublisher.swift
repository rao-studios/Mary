//
//  SelectionHandoffPublisher.swift
//  MaryBrain
//
//  WHAT: Adapter from an application's AX selection state to Mary's source-owned contract.
//  IN:   AXSelectionReader.FocusedSelectionSample
//  OUT:  AmbientContextStore.recordSelection / clearSelection
//  PIN:  Plugins supply application and optional document context; this type owns state semantics.
//
import Foundation

public enum SelectionHandoffPublisher {

    /// Classify and, where possible, publish source evidence.
    @discardableResult
    public static func captureOutcome(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        ambient: AmbientContextStore,
        place: AmbientPlace,
        applicationID: String,
        subject: String? = nil,
        channel: AmbientSelectionCaptureChannel,
        /// A source losing focus can report an empty transient value, whereas a source that is
        /// still frontmost at hands-free speech start has authoritatively told us there is only a
        /// caret. The coordinator supplies this distinction; no document/focus routing is involved.
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
            // A handoff happens at a focus boundary, where the focused AX element can vanish or change
            // before the callback reads it. It may publish positive evidence, but an empty value there
            // is not reliable enough to erase a source packet.
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

    /// Compatibility adapter for pollers and tests that only need to know whether an ambient
    /// mutation was applied. Handoff callbacks use `captureOutcome` so they retain
    /// unreadable/ambiguous source evidence. Publish only evidence that has an unambiguous.
    @discardableResult
    public static func publish(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        ambient: AmbientContextStore,
        place: AmbientPlace,
        applicationID: String,
        subject: String? = nil,
        channel: AmbientSelectionCaptureChannel,
        /// A source losing focus can report an empty transient value, whereas a source that is
        /// still frontmost at hands-free speech start has authoritatively told us there is only a
        /// caret. The coordinator supplies this distinction; no document/focus routing is involved.
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
