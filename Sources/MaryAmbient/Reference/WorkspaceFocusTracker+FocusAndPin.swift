//
//  WorkspaceFocusTracker+FocusAndPin.swift
//  MaryAmbient
//
//  WHAT: Activation, pin, and current() overlays (override > pin > ambient).
//  IN:   WorkspaceFocusTracker.swift (split)
//  OUT:  AmbientContextStore.noteLead / PinnedWorld
//

import AppKit
import Foundation
import os

extension WorkspaceFocusTracker {


    func noteActivation(_ world: AmbientWorld) {
        AmbientContextStore.shared.noteAttention(.init(tier: .activation, world: world))
    }

    /// Suppress ambient signals while Mary is driving an app — those activations are ceremony, not intent.
    public func suppress(for interval: TimeInterval) {
        suppressBox.withLock { $0 = Date().addingTimeInterval(interval) }
    }

    /// Open-ended suppression for self-driving work whose duration is unknown up front.
    public func beginSelfDriving() -> UUID {
        let id = UUID()
        holdsBox.withLock { _ = $0.insert(id) }
        return id
    }

    public func endSelfDriving(_ id: UUID, tail: TimeInterval = 10) {
        let removed = holdsBox.withLock { $0.remove(id) != nil }
        guard removed else { return }
        suppress(for: tail)
    }

    /// Single write seam — freshest activity wins. Window focus and watchers both call this.
    public func note(
        _ focus: WorkspaceFocus, place: AmbientPlace, at now: Date = Date()
    ) {
        guard signalsAllowed(at: now) else { return }
        if focus == .writing { writingPlaceBox.withLock { $0 = place } }
        box.withLock { $0 = (focus, now) }
        leadBox.withLock { $0 = (place, now) }
        stampEvidence(place: place, kind: .activity)
    }

    /// Shorthand for `note(.writing, place:)`.
    public func noteWriting(place: AmbientPlace) {
        note(.writing, place: place)
    }

    /// Place the current `.writing` signal belongs. Nil if nobody has written yet.
    /// PIN: During an override the pin stands aside — ambient truth for that turn.
    public func writingPlace() -> AmbientPlace? {
        func ambient() -> AmbientPlace? { writingPlaceBox.withLock { $0 } }
        if overrideBox.withLock({ $0 }) != nil { return ambient() }
        if let pin = pinBox.withLock({ $0 }), pin.focus == .writing { return pin.place }
        return ambient()
    }

    // MARK: - Sticky pin (the debugger's focus-correction control)

    public func pin(_ world: PinnedWorld) {
        pinBox.withLock { $0 = world }
    }

    public func clearPin() {
        pinBox.withLock { $0 = nil }
    }

    public func pinned() -> PinnedWorld? {
        pinBox.withLock { $0 }
    }

    func signalsAllowed(at now: Date = Date()) -> Bool {
        guard holdsBox.withLock({ $0.isEmpty }) else { return false }
        let suppressed = suppressBox.withLock { until -> Bool in
            if let until, now < until { return true }
            until = nil
            return false
        }
        return !suppressed
    }

    /// How long an ambient signal still describes where the user is.
    public static let signalHorizon: TimeInterval = 20 * 60

    public func current(at now: Date = Date()) -> WorkspaceFocus? {
        box.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.signalHorizon
            else { return nil }
            return held.focus
        }
    }

    /// Whether a writing app is genuinely in play — gate `WorkspaceFocusArbiter` uses.
    /// PIN: Override and pin are not consulted; both already resolve to `.writing`.
    public func writingInPlay(at now: Date = Date()) -> Bool {
        box.withLock { held in
            guard let held, held.focus == .writing else { return false }
            return now.timeIntervalSince(held.at) <= Self.signalHorizon
        }
    }

    /// Utterance-aware focus: override > pin > ambient. `current()` stays window truth.
    public func effectiveFocus() -> WorkspaceFocus? {
        if let override = overrideBox.withLock({ $0 }) { return override }
        if let pin = pinBox.withLock({ $0 }) { return pin.focus }
        return current()
    }

    public func setTurnOverride(_ focus: WorkspaceFocus?) {
        overrideBox.withLock { $0 = focus }
    }

    public func clearTurnOverride() {
        overrideBox.withLock { $0 = nil }
    }

    public func setForTesting(_ focus: WorkspaceFocus?) {
        box.withLock { $0 = focus.map { ($0, Date()) } }
    }
}
