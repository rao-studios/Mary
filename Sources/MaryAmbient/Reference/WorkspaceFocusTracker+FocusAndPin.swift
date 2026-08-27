//
//  WorkspaceFocusTracker+FocusAndPin.swift
//

import AppKit
import Foundation
import os

extension WorkspaceFocusTracker {


    func noteActivation(_ world: AmbientWorld) {
        AmbientContextStore.shared.noteAttention(.init(tier: .activation, world: world))
    }

    // THE SCRIVENER BUNDLE CONSTANTS ARE GONE (2026-08-15).
    //
    // They were the last compiled statement of "which process is Scrivener",
    // and this file's own header always licensed their removal: "A host with
    // different worlds replaces this file, or supplies its own registry."
    // The registry is `ApplicationRegistration`, the family is
    // `bundleIdentifierPrefix` — declared once in the package and answered
    // once by `owns(bundleID:)` — and the exact ids stay `bundleIdentifiers`
    // for the things that cannot take a family: launching, Automation
    // consent, permission targets, and the typer's typing target.

    /// While Mary itself drives an app, the signals that follow are
    /// ARTIFACTS of Mary's ceremony, not the user's intent: a Scrivener
    /// paste activates Scrivener (didActivate → record), the poll loops
    /// sample that frontmost, and the autosave advances the manuscript mtime
    /// (noteWritingActivity). Recording any of them would flip the arbiter so
    /// the NEXT turn follows Mary's own side effect. Suppress the whole
    /// window; the pre-ceremony state — the user's true focus — survives
    /// untouched. A genuine app switch inside the window is re-recorded by
    /// the 1.5s watcher polls right after it expires.
    public func suppress(for interval: TimeInterval) {
        suppressBox.withLock { $0 = Date().addingTimeInterval(interval) }
    }

    /// Open-ended suppression for self-driving work whose duration is
    /// unknown up front (a 60-second typed passage outlives any fixed
    /// window). Signals are ignored while ANY hold is open; `end` closes the
    /// hold and arms a fixed TAIL to swallow the trailing echoes (autosave
    /// mtime, the last poll samples). Refcounted: overlapping holds nest.
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

    /// The single write seam: the freshest activity wins. Called by
    /// record(bundleID:) for window focus and by the watchers for real work.
    /// No-op while suppressed (a Mary-driven ceremony is in flight).
    /// Stamps the unified lead box too — a native signal must displace a
    /// dynamic lead by the SAME recency rule that used to live as a
    /// cross-box comparison, and a background edit is exactly as native a
    /// signal as an activation.
    /// `at:` is the file's own `current(at:)` idiom on the write side: a test
    /// proving "the window expired" stamps a signal from past the window
    /// instead of blocking a cooperative-pool thread to wait it out.
    /// ONE SIGNAL METHOD: a discipline and the place it happened in.
    ///
    /// Bonnie had two — `note(_:)` for coding, which derived Xcode from the
    /// discipline, and `noteWriting(app:)` for writing, which took a closed
    /// enum. Both derivations only worked because the compiled worlds were
    /// countable. A caller here always knows WHERE the signal came from (it
    /// read a registration to learn the discipline in the first place), so
    /// the place is passed rather than guessed.
    public func note(
        _ focus: WorkspaceFocus, place: AmbientRealm, at now: Date = Date()
    ) {
        guard signalsAllowed(at: now) else { return }
        if focus == .writing { writingPlaceBox.withLock { $0 = place } }
        box.withLock { $0 = (focus, now) }
        leadBox.withLock { $0 = (place, now) }
        stampEvidence(realm: place, kind: .activity)
    }

    /// Writing activity from a place — the shorthand for `note(.writing,
    /// place:)`, kept because "the user is writing HERE" is the signal most
    /// callers mean.
    public func noteWriting(place: AmbientRealm) {
        note(.writing, place: place)
    }

    /// WHERE the current `.writing` signal belongs. Nil when nobody has
    /// written anywhere yet.
    ///
    /// OPTIONAL, DELIBERATELY. Bonnie's equivalent returned a closed enum
    /// that could not fail to answer, so before any writing happened it
    /// answered with a default — and a passage verb aimed at "the writing
    /// place" would land in an application the user had never opened. Nil is
    /// the honest form of that state and forces the caller to handle it.
    ///
    /// During an override turn the pin stands aside entirely: the turn
    /// behaves exactly as if unpinned, falling to ambient truth. A
    /// half-honoured pin — the override's discipline with the pin's place —
    /// is how an utterance about one document gets routed to another.
    public func writingPlace() -> AmbientRealm? {
        func ambient() -> AmbientRealm? { writingPlaceBox.withLock { $0 } }
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

    /// HOW LONG AN AMBIENT SIGNAL STILL DESCRIBES WHERE THE USER IS.
    ///
    /// `current()` had no decay at all: once a signal landed it stood until
    /// something else overwrote it, so a single glance at a writing app hours
    /// ago still asserted "the user is writing" on every turn since. Combined
    /// with a contribution gated on the app merely RUNNING, that is how a
    /// Pages document nobody had touched came to lead — and hand the voice a
    /// live-document block and a Pages deposit scope — on a question about the
    /// user's calendar.
    ///
    /// Deliberately generous. This is a staleness bound on an OBSERVATION, not
    /// an idle timer: someone reading a long document without touching the
    /// keyboard is still working in it, and every watcher re-samples the
    /// frontmost app every 1.5–10 s, so an app the user is actually in never
    /// comes close to this. Past it we simply stop asserting.
    public static let signalHorizon: TimeInterval = 20 * 60

    public func current(at now: Date = Date()) -> WorkspaceFocus? {
        box.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.signalHorizon
            else { return nil }
            return held.focus
        }
    }

    /// IS A WRITING APP GENUINELY IN PLAY? The gate `WorkspaceFocusArbiter`
    /// applies before a writing world may take the lead off the back of
    /// nothing but being open. True only while the ambient signal is a
    /// WRITING signal inside the horizon — window truth, not a running
    /// process.
    ///
    /// The override and the pin are deliberately NOT consulted: both already
    /// resolve to `.writing` through `effectiveFocus()`, and the arbiter's
    /// `.writing` branch never asks this question. "If I do name it, it must
    /// work" survives untouched.
    public func writingInPlay(at now: Date = Date()) -> Bool {
        box.withLock { held in
            guard let held, held.focus == .writing else { return false }
            return now.timeIntervalSince(held.at) <= Self.signalHorizon
        }
    }

    /// The utterance-aware focus the prompt/roster should use:
    /// override > pin > ambient. A named domain wins for its turn; the pin
    /// wins over everything ambient; current() stays window truth untouched —
    /// neither a word nor a click rewrites where the user actually is.
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
