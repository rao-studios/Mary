//
//  SelectionHandoffCoordinator.swift
//  MaryBrain
//
//  Workspace activation is only a lifecycle signal. This coordinator lets an
//  enabled application's selection ability capture its own text when that app
//  yields focus; it never decides which application a turn should mean.
//

import AppKit
import ApplicationServices
import Foundation
import os

public final class SelectionHandoffCoordinator: @unchecked Sendable {
    public static let shared = SelectionHandoffCoordinator()

    /// Why the source ability is being asked to sample. The trigger affects
    /// only whether a confirmed caret is meaningful: while an app is yielding
    /// focus an empty AX value is ambiguous, while it is still frontmost at
    /// speech start it is an authoritative no-selection result. Neither case
    /// is a workspace-focus decision.
    public enum CaptureTrigger: Sendable, Equatable {
        case sourceDeactivation
        case pendingRaceBarrier
        case activeSourcePreflight
    }

    /// The source ability's result.  `handledButUnpublishable` is distinct
    /// from `noEvidence`: Accessibility can prove that a source has a
    /// nonempty selection range without being able to hydrate its text, or a
    /// canvas walk can find two competing positive descendants.  In either
    /// case a generic second read must not choose a different leaf merely
    /// because it happened to arrive later.
    public enum CaptureOutcome: Sendable, Equatable {
        /// The source selection (or an authoritative caret clear) was applied.
        case published
        /// The specialist saw source evidence but correctly declined to invent
        /// a highlight from it.
        case handledButUnpublishable
        /// The specialist had no source evidence, so the generic ability may
        /// attempt the same application.
        case noEvidence

        public var handled: Bool { self != .noEvidence }

        public static func combining(_ lhs: Self, _ rhs: Self) -> Self {
            if lhs == .published || rhs == .published { return .published }
            if lhs == .handledButUnpublishable || rhs == .handledButUnpublishable {
                return .handledButUnpublishable
            }
            return .noEvidence
        }
    }

    typealias SourceCapture = @Sendable (CaptureTrigger) -> CaptureOutcome
    typealias AsyncSourceCapture = @Sendable (CaptureTrigger) async -> CaptureOutcome
    typealias GenericSourceCapture = @Sendable (String, CaptureTrigger) -> CaptureOutcome

    /// A capture hook reports whether it published, intentionally abstained
    /// after seeing source evidence, or found no evidence at all. The latter
    /// is the only result that permits the generic selection ability.
    let box = OSAllocatedUnfairLock<[
        String: [UUID: SourceCapture]
    ]>(initialState: [:])
    /// Some taught applications carry a major/distribution suffix in their
    /// bundle identifier. A family callback is still source-owned evidence,
    /// but it is matched with the same dot-boundary rule as ambient routing
    /// rather than forcing every future exact identifier into this process.
    let familyBox = OSAllocatedUnfairLock<[
        String: [UUID: SourceCapture]
    ]>(initialState: [:])
    /// Request-boundary capture may need an application-owned asynchronous
    /// transaction. Pages uses this only after AX proves a positive range but
    /// withholds its characters; ordinary exact AX handoffs remain on the
    /// synchronous path above.
    let asyncBox = OSAllocatedUnfairLock<[
        String: [UUID: AsyncSourceCapture]
    ]>(initialState: [:])
    /// The generic selection ability cannot know its source app until
    /// deactivation. These callbacks receive that source id and decide whether
    /// they can capture it after a specialist reports no usable evidence.
    let anySourceBox = OSAllocatedUnfairLock<[
        UUID: GenericSourceCapture
    ]>(
        initialState: [:])
    /// Workspace notifications can arrive one run-loop turn after a request
    /// begins. Keep a bounded, lifecycle-only bridge so `MaryBrain.runTurn`
    /// can synchronously ask the just-yielded source for its selection before
    /// taking the immutable turn snapshot. This is not focus routing: it is
    /// only a bounded retry of the same source capture callback.
    struct LifecycleState {
        /// Activation is the sole owner of this value. A delayed
        /// deactivation may arm a retry, but must never rewrite it.
        var lastSourceApplicationID: String?
        var pendingSource: (applicationID: String, expiresAt: Date)?
    }
    let lifecycleBox = OSAllocatedUnfairLock<LifecycleState>(initialState: .init())
    /// The source transition remains useful for exactly as long as a captured
    /// selection could remain useful. The former three-second lease expired
    /// while a user typed even a short question into Mary, making Pages'
    /// request-time fallback unreachable although no other app had activated.
    /// External activation still revokes the lease immediately, and capture
    /// remains one-shot, so widening this to the Interaction freshness window
    /// does not turn remembered focus into routing authority.
    static let preTurnCaptureWindow: TimeInterval =
        AmbientSelectionHandoff.handoffFreshFor

    public init() {}
}
