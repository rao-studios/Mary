//
//  WorkspaceFocusTracker.swift
//  MaryBrain
//
//  Which world is the user in — code or manuscript? Holds the most recent
//  ACTIVITY across {Xcode, Scrivener}: window activations AND real work
//  (a code edit / cursor move, a manuscript change). Everything else
//  (Mary's own window, Terminal, a browser) leaves the signal alone,
//  because glancing at a browser doesn't change what you're working on. The
//  prompt provider and the Skill-roster hoist read it synchronously each turn.
//
//  Fed three ways, all funnelling through `note(_:)`: the watcher poll loops
//  call sample() (so headless probes work with zero app-layer machinery),
//  the app layer forwards NSWorkspace didActivate into record(bundleID:) for
//  instant window transitions, and each watcher calls note(...) when it sees
//  its app actually being worked in (so a backgrounded edit still counts —
//  the "auto-follow" behavior). No signal yet → nil → callers default to
//  coding-first, today's exact behavior.
//
//  Two overlays sit above the ambient signal, in strict precedence:
//  override > pin > ambient. The per-turn OVERRIDE — the utterance named a
//  domain ("add a scene…", "fix the build…") — wins for exactly its turn.
//  Below it, a sticky PIN (the debugger's "watch THIS world" click) holds
//  until explicitly cleared. Window truth stays on current() — neither a
//  word nor a click rewrites where the user actually is.
//

import AppKit
import Foundation
import os


public final class WorkspaceFocusTracker: Sendable {

    public static let shared = WorkspaceFocusTracker()

    let box = OSAllocatedUnfairLock<(focus: WorkspaceFocus, at: Date)?>(initialState: nil)
    /// Turn-scoped override from the utterance; overlays `current()` via
    /// `effectiveFocus()`. Set at the top of a turn, cleared when it ends.
    let overrideBox = OSAllocatedUnfairLock<WorkspaceFocus?>(initialState: nil)
    /// While set (and in the future), every signal is ignored — see suppress().
    let suppressBox = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// WHERE THE WRITING SIGNAL CAME FROM — nil until one arrives.
    ///
    /// ONE BOX, because there is one kind of answer. Bonnie carried two: a
    /// closed `WritingApp` enum for its compiled writing worlds, and this
    /// place as an escape hatch for applications taught by package. The enum
    /// always answered SOMETHING — it had no way not to — so a taught
    /// application's autosave was detected and then thrown away, and a
    /// default meant for one app came to answer for another. Every
    /// application is taught in Mary, so the escape hatch is the whole road,
    /// and nil honestly means "nobody has written anywhere yet".
    let writingPlaceBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    /// User-planted pin; overlays ambient below the turn override. NOT gated
    /// by signalsAllowed() — a debugger click is user intent, not a ceremony
    /// echo, so it lands even mid-suppress/mid-self-driving.
    let pinBox = OSAllocatedUnfairLock<PinnedWorld?>(initialState: nil)
    /// Live self-driving holds (Mary typing, a menu ceremony) — while ANY
    /// hold is open, signals are ignored regardless of the deadline above.
    let holdsBox = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    /// WHICH REALM last asserted the lead — ONE box for both cases of the
    /// identity. The native arms of `record(bundleID:)` and the watchers'
    /// real-work signals stamp `.lane(world)`; a registered dynamic
    /// application's activation/activity stamps its registration's place.
    /// Recency between the two used to be a cross-box comparison (the
    /// deleted dynamic-channel read peeking at `box`); with one box it is
    /// trivial ordering — whoever stamped last leads. `box` stays beside it
    /// untouched, because focus (`.coding`/`.writing`) is vocabulary the
    /// arbiter ranks and a place is an address; they decay on the same
    /// horizon but answer different questions.
    let leadBox =
        OSAllocatedUnfairLock<(place: AmbientPlace, at: Date)?>(initialState: nil)
    /// Per-app canvas-selection baseline for change detection — a standing
    /// selection re-reported every poll is not an interaction.
    let selectionBox =
        OSAllocatedUnfairLock<(id: String, signature: String)?>(initialState: nil)
    /// THE EVIDENCE LEDGER behind the single lead — one freshest stamp per
    /// place, written by the same funnels that stamp `leadBox` plus the
    /// glance responder. `leadBox` stays authoritative for the lead;
    /// `signal()` projects this into the co-active set. Bounded by nature (a
    /// handful of places exist per session) and swept on read.
    let ledgerBox =
        OSAllocatedUnfairLock<[AmbientPlace: FocusEvidence]>(initialState: [:])

    public init() {}

    /// TCC-free frontmost read; polling NSWorkspace has precedent
    /// (`ApplicationMenuDriver`) — no observers inside MaryBrain.
    public func sample() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        record(
            bundleID: frontmost?.bundleIdentifier,
            localizedName: frontmost?.localizedName)
    }

    /// BUNDLES THAT MUST NEVER DISPLACE THE LEAD: Mary's own window (the
    /// user speaking to Mary is not a workspace change), and system chrome
    /// whose activation is an artifact, not a destination. Prefix-matched.
    /// FINDER IS EVIDENCE-ONLY by user decision (2026-08-11): a desktop
    /// misclick activates it constantly, so it co-activates but never leads.
    public static let leadExcludedBundlePrefixes: [String] = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver",
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.SecurityAgent",
    ]
    public static let finderBundleID = "com.apple.finder"

    /// Mary's overlay and system chrome do not count as leaving a workspace.
    /// A nil bundle — no frontmost process at all — is the same situation:
    /// the user is speaking to Mary, not working in a different application.
    ///
    /// THE FAILURE THIS NAMES. `CodeSurfaceObserver` used to walk only
    /// `NSWorkspace.frontmostApplication`. Asking Mary with her own window
    /// up made that read Mary's process, skipped the standing Xcode, and
    /// Lane A spoke the blindness clause ("paste the code") while Xcode was
    /// still the active coding workspace. Transparent frontmost is the
    /// tracker's own rule, asked of the observer so both agree.
    public static func isWorkspaceTransparent(
        bundleID: String?,
        maryBundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleID else { return true }
        if let maryBundleID, bundleID == maryBundleID { return true }
        return leadExcludedBundlePrefixes.contains(where: bundleID.hasPrefix)
    }

    /// Map a bundle id to a focus and record it. sample() and the app-layer
    /// activation observer both funnel here. Bundle ids are owned by their
    /// domain plugins (one constant each); the tracker owns only the mapping.
    /// Scrivener matches by prefix so a Setapp/future build still registers.
    ///
    /// THE LADDER IS COMPLETE NOW (cursor-obvious lead, 2026-08-11): the app
    /// the user activates leads — native arms, registered dynamics, the
    /// browser workspace, and a terminal else for every generic app. Before
    /// the terminal arm, an unregistered frontmost produced ZERO signal, so
    /// a stale Xcode lead stood for its whole 20-minute horizon while the
    /// user plainly watched a video in a browser ("led: Xcode" — the
    /// incident).
    public func record(bundleID: String?, localizedName: String? = nil) {
        guard let bundleID, signalsAllowed() else { return }
        // Mary's own window and system chrome never displace.
        if Self.isWorkspaceTransparent(bundleID: bundleID) { return }
        // NO COMPILED-APPLICATION ARMS. Bonnie opened this ladder with four
        // hardcoded bundle-id comparisons — Xcode, Pages, TextEdit, Keynote —
        // and every application taught by package had to be handled again
        // further down. Here the roster arm below is the only application
        // arm there is, so a taught application gets exactly the treatment a
        // compiled one used to, by construction rather than by remembering.
        if AmbientPlaceResolver.isBrowser(bundleID: bundleID) {
            // THE BROWSER IS A WORKSPACE (user decision, 2026-08-11), and it
            // LEADS (same day, after "led: Xcode" stood while the user
            // watched a video in a browser — cursor-obvious means the app
            // you're in wins). Same shape as noteDynamicApplication: lead +
            // ledger (with the concrete process behind the logical place) +
            // activation attention. `box` stays untouched (native
            // coding/writing vocabulary — D3).
            //
            // ABOVE the registration arm on purpose (the browser carve-out,
            // mirrored in AmbientPlaceResolver.factPlace(forBundleID:)): a
            // dynamic package may register a browser bundle (chrome.mary),
            // but a Chrome activation must keep stamping the ONE browser
            // workspace with its concrete process id, never
            // noteDynamicApplication("chrome") — else the browser lane's
            // ledger and facts split by engine.
            AmbientApplicationDirectory.shared.note(
                bundleID: bundleID, name: localizedName)
            leadBox.withLock { $0 = (AmbientPlaceResolver.browserPlace, Date()) }
            stampEvidence(
                place: AmbientPlaceResolver.browserPlace, kind: .activation,
                processBundleID: bundleID)
            AmbientContextStore.shared.noteAttention(.init(
                tier: .activation, world: .applications,
                subject: AmbientPlaceResolver.browserApplicationID,
                applicationID: AmbientPlaceResolver.browserApplicationID))
        } else if let registration = AmbientApplicationIndexProvider.current
                      .registration(bundleID: bundleID),
                  registration.legacyWorld == nil {
            // A registered DYNAMIC application (Sketch) is a workspace the
            // user can evidently be in, exactly like the four native arms
            // above. Before this arm, a Sketch activation fell through
            // silently, so the lead survived only on a frontmost read at
            // utterance time — and speaking while Mary's own window was
            // front handed the turn to whatever stale native lead remained.
            // No roster installed → EmptyAmbientApplicationIndex → inert.
            //
            // A TAUGHT APPLICATION WITH EYES IS A WRITING WORKSPACE, not just
            // an activation: an activation stamps the lead and stops, and the
            // arbiter's register comes from the `.writing`/`.coding`
            // vocabulary rather than from who led. Reading the discipline off
            // the registration is the same edge `AmbientEngine.classify`
            // already draws, so a manuscript application the user installed
            // gets the writing register on activation exactly as Pages does.
            if registration.hasEyes, let focus = registration.place.focus {
                note(focus, place: registration.place)
            }
            noteDynamicApplication(registration.id)
        } else if bundleID == Self.finderBundleID {
            // FINDER: evidence only, never the lead (user decision — a
            // desktop misclick activates it constantly).
            stampEvidence(
                place: AmbientPlaceResolver.applicationPlace(forBundleID: bundleID),
                kind: .activation, processBundleID: bundleID)
        } else {
            // THE TERMINAL ARM — every generic app. The user activated it;
            // cursor-obvious means it leads, carrying its own identity (the
            // bundle id; display name via the directory).
            noteGenericApplication(bundleID: bundleID, localizedName: localizedName)
        }
    }

}
