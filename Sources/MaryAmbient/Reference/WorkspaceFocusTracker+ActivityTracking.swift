//
//  WorkspaceFocusTracker+ActivityTracking.swift
//

import AppKit
import Foundation
import os

extension WorkspaceFocusTracker {

    /// A generic (unregistered, non-browser) application became the user's
    /// evident workspace. `noteDynamicApplication`'s shape with an
    /// identity-bearing realm.
    func noteGenericApplication(bundleID: String, localizedName: String?) {
        AmbientApplicationDirectory.shared.note(
            bundleID: bundleID, name: localizedName)
        let realm = AmbientRealmResolver.applicationRealm(forBundleID: bundleID)
        leadBox.withLock { $0 = (realm, Date()) }
        stampEvidence(realm: realm, kind: .activation, processBundleID: bundleID)
        AmbientContextStore.shared.noteAttention(.init(
            tier: .activation, world: .applications,
            subject: localizedName ?? bundleID,
            applicationID: bundleID))
    }

    /// A SUCCESSFUL LOOK at this realm's app. A glance is sight, not
    /// presence: it never touches `box`/`leadBox`, so the lead cannot be
    /// hijacked by looking around — but the glanced realm co-activates, which
    /// is what carries "look at the doc in that window" into "now help me
    /// write it in Pages". NOT gated by `signalsAllowed()`: the look is the
    /// user's own deliberate ask (like `pin`), not a ceremony echo.
    public func noteGlance(realm: AmbientRealm) {
        stampEvidence(realm: realm, kind: .glance, gated: false)
    }

    /// A WATCHER SAW REAL WORK in a realm it does not lead. Stamps ledger
    /// evidence ONLY — never `leadBox`, never `box`: a browser's lead already
    /// arrives through `record(bundleID:)`, and a tab changing in a
    /// background window is not the user moving there. Gated like every
    /// ambient signal, so a self-driving hold or a ceremony echo still
    /// suppresses it.
    public func noteWork(realm: AmbientRealm, processBundleID: String? = nil) {
        stampEvidence(
            realm: realm, kind: .activity, processBundleID: processBundleID)
    }

    /// One write seam for the ledger. Glances never downgrade stronger fresh
    /// evidence: looking at the Pages window while actively writing in it
    /// must not turn activity into a mere glance.
    func stampEvidence(
        realm: AmbientRealm, kind: FocusEvidenceKind, gated: Bool = true,
        processBundleID: String? = nil
    ) {
        if gated { guard signalsAllowed() else { return } }
        let now = Date()
        ledgerBox.withLock { ledger in
            if kind == .glance,
               let held = ledger[realm],
               held.kind > .glance,
               now.timeIntervalSince(held.at) <= FocusSignal.horizon(for: held.kind) {
                return
            }
            ledger[realm] = FocusEvidence(
                realm: realm, kind: kind, at: now,
                processBundleID: processBundleID ?? ledger[realm]?.processBundleID)
        }
    }

    /// The realm of the FRESHEST live glance — "what did Mary just look
    /// at". The referent-arming seam reads this right after a served
    /// pre-lane look, so the NEXT turn's "here"/"it" can inherit the
    /// looked-at application (the live miss: the look described a Google
    /// Doc, nothing armed, and "add a draft here" circled into TextEdit).
    public func latestGlanceRealm(at now: Date = Date()) -> AmbientRealm? {
        ledgerBox.withLock { ledger in
            ledger.values
                .filter {
                    $0.kind == .glance
                        && now.timeIntervalSince($0.at) <= FocusSignal.glanceHorizon
                }
                .max { $0.at < $1.at }?
                .realm
        }
    }

    /// The concrete process behind one realm's freshest evidence, while
    /// fresh — `type_in_web_page`'s "which browser was the user just in".
    public func evidenceProcess(for realm: AmbientRealm, at now: Date = Date()) -> String? {
        ledgerBox.withLock { ledger in
            guard let held = ledger[realm],
                  now.timeIntervalSince(held.at) <= FocusSignal.horizon(for: held.kind)
            else { return nil }
            return held.processBundleID
        }
    }

    /// The same question against an EXPLICIT horizon. The browser-resolution
    /// ladder's recent-evidence rung passes `signalHorizon` (20 min): the
    /// user who worked in Chrome twelve minutes ago has let the co-active
    /// horizon lapse, but the lead's own staleness bound still honestly
    /// answers "which browser was that" — the identical bound the lead
    /// itself stands on.
    public func evidenceProcess(
        for realm: AmbientRealm,
        within horizon: TimeInterval,
        at now: Date = Date()
    ) -> String? {
        ledgerBox.withLock { ledger in
            guard let held = ledger[realm],
                  now.timeIntervalSince(held.at) <= horizon
            else { return nil }
            return held.processBundleID
        }
    }

    /// THE PROJECTED RESPONDER-LAYER SIGNAL. `lead` is exactly
    /// `leadRealm(at:)` — the parity rule: single-realm sessions answer
    /// byte-identically to the pre-ledger tracker. `coActive` is every other
    /// realm with fresh evidence, strongest-evidence-then-recency ranked;
    /// `glanced` marks the ones whose only claim is sight.
    public func signal(at now: Date = Date()) -> FocusSignal {
        let lead = leadRealm(at: now)
        let fresh = ledgerBox.withLock { ledger -> [FocusEvidence] in
            ledger = ledger.filter {
                now.timeIntervalSince($0.value.at)
                    <= FocusSignal.horizon(for: $0.value.kind)
            }
            return Array(ledger.values)
        }
        let ranked = fresh
            .filter { $0.realm != lead }
            .sorted {
                $0.kind == $1.kind ? $0.at > $1.at : $0.kind > $1.kind
            }
        return FocusSignal(
            lead: lead,
            coActive: ranked.map(\.realm),
            glanced: Set(ranked.filter { $0.kind == .glance }.map(\.realm)))
    }

    /// A registered dynamic application became the user's evident workspace.
    /// Same gating as `note()`: suppression and self-driving holds apply.
    /// Stamps the unified lead box with the registration's own place — the
    /// raw host-lane pair is the fallback for an id the index has not
    /// caught up with (`record` only routes registered ids here, so the
    /// fallback is the same pair the registration would spell).
    public func noteDynamicApplication(_ id: String) {
        guard signalsAllowed() else { return }
        let place = AmbientApplicationIndexProvider.current
            .registration(id: id)?.place
            ?? AmbientRealm(world: .applications, application: id)
        leadBox.withLock { $0 = (place, Date()) }
        stampEvidence(realm: place, kind: .activation)
        // The activation-tier attention the native arms mint, in the lane
        // vocabulary dynamic facts already use (.applications + application id).
        AmbientContextStore.shared.noteAttention(
            .init(tier: .activation, world: .applications, subject: id, applicationID: id))
    }

    /// A CHANGED canvas selection is evidence of the user working in the app
    /// — the dynamic analogue of a native watcher's `noteWriting` on real
    /// work. The first sighting only BASELINES (a standing selection Mary
    /// booted into is not an interaction); a later different signature
    /// refreshes the dynamic record. An unchanged selection re-reported
    /// every poll asserts nothing.
    public func noteDynamicSelection(application id: String, signature: String) {
        guard signalsAllowed() else { return }
        let changed: Bool = dynamicSelectionBox.withLock { last in
            defer { last = (id, signature) }
            guard let last else { return false }
            return last.id != id || last.signature != signature
        }
        guard changed,
              let registration = AmbientApplicationIndexProvider.current
                  .registration(id: id),
              registration.legacyWorld == nil
        else { return }
        leadBox.withLock { $0 = (registration.place, Date()) }
        stampEvidence(realm: registration.place, kind: .activity)
    }

    /// The REALM that currently deserves the lead, or nil. Mirrors
    /// `effectiveFocus()` precedence: a turn override or a pin (both native
    /// vocabulary today) outranks ambient evidence; below them the unified
    /// box answers directly — the freshest stamp already won at write time,
    /// bounded by `signalHorizon`. A native realm carries a nil application
    /// lane, which is what lets callers that only care about dynamic leads
    /// project `leadRealm()?.application` and fall through on native ones.
    public func leadRealm(at now: Date = Date()) -> AmbientRealm? {
        guard overrideBox.withLock({ $0 }) == nil,
              pinBox.withLock({ $0 }) == nil else { return nil }
        return leadBox.withLock { held in
            guard let held, now.timeIntervalSince(held.at) <= Self.leadHorizon
            else { return nil }
            return held.realm
        }
    }

    /// HOW LONG A LEAD KEEPS LEADING — deliberately shorter than
    /// `signalHorizon`, which it used to share.
    ///
    /// The two answer different questions. `signalHorizon` bounds an
    /// OBSERVATION ("the user was last seen in a writing app") and its
    /// generosity is argued correctly where it is declared. This bounds an
    /// ASSERTION ("this realm is what the turn is about"), which grounds the
    /// prompt and paints the lead badge — a much stronger claim on much the
    /// same evidence, and it was outliving that evidence by fifteen minutes.
    /// The tree's own comments name the result twice: "a stale Xcode lead
    /// stood for its whole 20-minute horizon while the user plainly watched a
    /// video in a browser", and the quit-app variant beside `clearNative`.
    ///
    /// `clearNative`/`clearLead` already withdraw a lead whose app QUIT. This
    /// covers the other half — the app that is still running and has simply
    /// been abandoned, which is the case in the screenshots.
    ///
    /// Same value as `AmbientContextStore.leadHorizon` and for the same
    /// reason: both are copies of one claim, and a copy that asserts longer
    /// than its source is the stale-lead bug wearing another coat.
    public static let leadHorizon: TimeInterval = FocusSignal.coActiveHorizon

    /// Lifecycle stand-down: the application quit; ambient evidence must
    /// not outlive it. Scoped to one lane — a native lead never matches an
    /// application id, so only the quitting app's own claim is withdrawn.
    public func clearLead(ifApplication id: String) {
        leadBox.withLock { if $0?.realm.application == id { $0 = nil } }
        ledgerBox.withLock { ledger in
            for realm in ledger.keys where realm.application == id {
                ledger[realm] = nil
            }
        }
    }

    /// Lifecycle stand-down for a NATIVE workspace app: the process quit, so
    /// its ambient claims — the lead, its ledger evidence, and the
    /// coding/writing focus signal it stamped — must not outlive it. The
    /// mirror of `clearLead(ifApplication:)`, which can never match a native
    /// realm (a native place carries a nil application lane — which is
    /// exactly how a quit Xcode's stale `.coding` box survived 20 minutes
    /// and led a turn about a YouTube video). Deliberately leaves the
    /// override and the pin alone: a word and a click are user intent, not
    /// ambient evidence.
    public func clearNative(world: AmbientWorld) {
        leadBox.withLock { if $0?.realm == AmbientRealm.world(world) { $0 = nil } }
        ledgerBox.withLock { $0[AmbientRealm.world(world)] = nil }
        // The held discipline belongs to a PLACE, and a lane is not a place.
        // Bonnie compared the quitting world against a compiled writing app
        // here, guarding against "quitting Pages clears Scrivener's claim";
        // Mary's equivalent guard is the realm comparison below, and it is
        // exact rather than by-world.
        box.withLock { held in
            guard held?.focus == .writing else { return }
            if writingPlaceBox.withLock({ $0 }) == AmbientRealm.world(world) {
                held = nil
            }
        }
    }

}
