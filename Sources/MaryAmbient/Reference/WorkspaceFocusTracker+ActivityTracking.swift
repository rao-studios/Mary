//
//  WorkspaceFocusTracker+ActivityTracking.swift
//  MaryAmbient
//
//  WHAT: Activity stamps into the focus ledger (generic apps, writing, coding).
//  IN:   WorkspaceFocusTracker.swift (split)
//  OUT:  leadBox / FocusSignal
//

import AppKit
import Foundation
import os

extension WorkspaceFocusTracker {

    /// A generic (unregistered, non-browser) application became the user's
    /// evident workspace. `noteDynamicApplication`'s shape with an
    /// identity-bearing place.
    func noteGenericApplication(bundleID: String, localizedName: String?) {
        AmbientApplicationDirectory.shared.note(
            bundleID: bundleID, name: localizedName)
        let place = AmbientPlaceResolver.applicationPlace(forBundleID: bundleID)
        leadBox.withLock { $0 = (place, Date()) }
        stampEvidence(place: place, kind: .activation, processBundleID: bundleID)
        AmbientContextStore.shared.noteWorld(.init(
            sense: .workspace, attention: .applications,
            subject: localizedName ?? bundleID,
            applicationID: bundleID))
    }

    /// A SUCCESSFUL LOOK at this place's app.
    public func noteGlance(place: AmbientPlace) {
        stampEvidence(place: place, kind: .glance, gated: false)
    }

    /// A WATCHER SAW REAL WORK in a place it does not lead. Stamps ledger evidence ONLY — never
    /// `leadBox`, never `box`: a browser's lead already arrives through `record(bundleID:)`,
    /// and a tab changing in a background window is not the user moving there.
    public func noteWork(place: AmbientPlace, processBundleID: String? = nil) {
        stampEvidence(
            place: place, kind: .activity, processBundleID: processBundleID)
    }

    /// One write seam for the ledger. Glances never downgrade stronger fresh
    /// evidence: looking at the Pages window while actively writing in it
    /// must not turn activity into a mere glance.
    func stampEvidence(
        place: AmbientPlace, kind: FocusEvidenceKind, gated: Bool = true,
        processBundleID: String? = nil
    ) {
        if gated { guard signalsAllowed() else { return } }
        let now = Date()
        ledgerBox.withLock { ledger in
            if kind == .glance,
               let held = ledger[place],
               held.kind > .glance,
               now.timeIntervalSince(held.at) <= FocusSignal.horizon(for: held.kind) {
                return
            }
            ledger[place] = FocusEvidence(
                place: place, kind: kind, at: now,
                processBundleID: processBundleID ?? ledger[place]?.processBundleID)
        }
    }

    /// The place of the FRESHEST live glance — "what did Mary just look at".
    public func latestGlancePlace(at now: Date = Date()) -> AmbientPlace? {
        ledgerBox.withLock { ledger in
            ledger.values
                .filter {
                    $0.kind == .glance
                        && now.timeIntervalSince($0.at) <= FocusSignal.glanceHorizon
                }
                .max { $0.at < $1.at }?
                .place
        }
    }

    /// The concrete process behind one place's freshest evidence, while
    /// fresh — `type_in_web_page`'s "which browser was the user just in".
    public func evidenceProcess(for place: AmbientPlace, at now: Date = Date()) -> String? {
        ledgerBox.withLock { ledger in
            guard let held = ledger[place],
                  now.timeIntervalSince(held.at) <= FocusSignal.horizon(for: held.kind)
            else { return nil }
            return held.processBundleID
        }
    }

    /// The same question against an EXPLICIT horizon.
    public func evidenceProcess(
        for place: AmbientPlace,
        within horizon: TimeInterval,
        at now: Date = Date()
    ) -> String? {
        ledgerBox.withLock { ledger in
            guard let held = ledger[place],
                  now.timeIntervalSince(held.at) <= horizon
            else { return nil }
            return held.processBundleID
        }
    }

    /// THE FRESH EVIDENCE ITSELF, unranked and unprojected. `signal(at:)` below answers "who
    /// leads and who else is warm", which is what the prompt needs.
    public func freshEvidence(at now: Date = Date()) -> [AmbientPlace: FocusEvidence] {
        ledgerBox.withLock { ledger in
            ledger = ledger.filter {
                now.timeIntervalSince($0.value.at)
                    <= FocusSignal.horizon(for: $0.value.kind)
            }
            return ledger
        }
    }

    /// THE PROJECTED RESPONDER-LAYER SIGNAL. `lead` is exactly `leadPlace(at:)` — the parity
    /// rule: single-place sessions answer byte-identically to the pre-ledger tracker.
    public func signal(at now: Date = Date()) -> FocusSignal {
        let lead = leadPlace(at: now)
        let fresh = ledgerBox.withLock { ledger -> [FocusEvidence] in
            ledger = ledger.filter {
                now.timeIntervalSince($0.value.at)
                    <= FocusSignal.horizon(for: $0.value.kind)
            }
            return Array(ledger.values)
        }
        let ranked = fresh
            .filter { $0.place != lead }
            .sorted {
                $0.kind == $1.kind ? $0.at > $1.at : $0.kind > $1.kind
            }
        return FocusSignal(
            lead: lead,
            coActive: ranked.map(\.place),
            glanced: Set(ranked.filter { $0.kind == .glance }.map(\.place)),
            lookTarget: paneBox.withLock { $0 })
    }

    /// Stamp the tagged editor pane whose bbox look_at_screen should use first.
    public func notePaneTarget(_ target: FocusPaneTarget?) {
        paneBox.withLock { $0 = target }
    }

    /// A registered dynamic application became the user's evident workspace. Same gating as
    /// `note()`: suppression and self-driving holds apply.
    public func noteDynamicApplication(_ id: String) {
        guard signalsAllowed() else { return }
        let place = AmbientApplicationIndexProvider.current
            .registration(id: id)?.place
            ?? AmbientPlace(attention: .applications, application: id)
        leadBox.withLock { $0 = (place, Date()) }
        stampEvidence(place: place, kind: .activation)
        // The workspace-sense attention the native arms mint, in the lane
        // vocabulary dynamic facts already use (.applications + application id).
        AmbientContextStore.shared.noteWorld(
            .init(sense: .workspace, attention: .applications, subject: id, applicationID: id))
    }

    /// A CHANGED canvas selection is evidence of the user working in the app — the dynamic
    /// analogue of a native watcher's `noteWriting` on real work.
    public func noteDynamicSelection(application id: String, signature: String) {
        guard signalsAllowed() else { return }
        let changed: Bool = selectionBox.withLock { last in
            defer { last = (id, signature) }
            guard let last else { return false }
            return last.id != id || last.signature != signature
        }
        guard changed,
              let registration = AmbientApplicationIndexProvider.current
                  .registration(id: id),
              registration.legacyAttention == nil
        else { return }
        leadBox.withLock { $0 = (registration.place, Date()) }
        stampEvidence(place: registration.place, kind: .activity)
    }

    /// The REALM that currently deserves the lead, or nil.
    public func leadPlace(at now: Date = Date()) -> AmbientPlace? {
        guard overrideBox.withLock({ $0 }) == nil,
              pinBox.withLock({ $0 }) == nil else { return nil }
        return leadBox.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.leadHorizon
            else { return nil }
            return held.place
        }
    }

    /// HOW LONG A LEAD KEEPS LEADING.
    public static let leadHorizon: TimeInterval = FocusSignal.coActiveHorizon

    /// Lifecycle stand-down: the application quit; ambient evidence must
    /// not outlive it. Scoped to one lane — a native lead never matches an
    /// application id, so only the quitting app's own claim is withdrawn.
    public func clearLead(ifApplication id: String) {
        leadBox.withLock { if $0?.place.application == id { $0 = nil } }
        ledgerBox.withLock { ledger in
            for place in ledger.keys where place.application == id {
                ledger[place] = nil
            }
        }
        paneBox.withLock { if $0?.place.application == id { $0 = nil } }
    }

    /// Lifecycle stand-down for a NATIVE workspace app: the process quit, so its ambient claims
    /// — the lead, its ledger evidence, and the coding/writing focus signal it stamped — must
    /// not outlive it.
    public func clearNative(attention: AmbientAttention) {
        leadBox.withLock { if $0?.place == AmbientPlace.lane(attention) { $0 = nil } }
        ledgerBox.withLock { $0[AmbientPlace.lane(attention)] = nil }
        // The held discipline belongs to a PLACE, and a lane is not a place.
        box.withLock { held in
            guard held?.focus == .writing else { return }
            if writingPlaceBox.withLock({ $0 }) == AmbientPlace.lane(attention) {
                held = nil
            }
        }
    }

}
