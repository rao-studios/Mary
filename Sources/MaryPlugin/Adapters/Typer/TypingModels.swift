//
//  TypingModels.swift
//  MaryBrain
//
//  Split out of TyperPlugin.swift (docs/DECOMPOSITION.md Wave 2) —
//  pure relocation, no declaration changed.
//

import AppKit
import Foundation
import os

// NO `TypingTarget`. Bonnie kept a compiled enum of the writing applications
// — pages, textEdit — so `type_at_cursor(app:)` could be validated against a
// closed set. Its own doc comment recorded the trap that shape creates: the
// raw value had to be spelled `"textedit"` by hand, because a synthesized
// `"textEdit"` would fail `init(rawValue:)` for the exact string the model
// sends and fall silently through to the frontmost rung — "a spelling gap
// that looks like nothing and behaves like a disabled parameter."
//
// Mary has no compiled applications, so the closed set would be empty and
// every rung that consulted it would be dead. What replaces it is the rung
// that was already here for taught applications: `taughtSurface(named:)`,
// gated on eyes and the writing discipline, asking the roster. One ladder,
// and a package installed this morning is as nameable as anything else.


/// The concrete text surface a typing run owns — a bundle id, a match prefix
/// and a name Mary can say. There is no compiled ceiling on where keyboard
/// writing may land: a surface is chosen from a taught application the user
/// named, a freshly staged document, the frontmost application, or a live
/// selection, and never guessed from an application name alone.
struct TypingSurface: Sendable, Equatable {
    /// The small, value-typed part of a running application needed for safe
    /// selection-source resolution. Keeping it separate from AppKit makes the
    /// routing rule testable without a live Notes/Pages process.
    struct RunningApplication: Sendable, Equatable {
        let bundleID: String
        let spokenName: String?

        init(bundleID: String, spokenName: String? = nil) {
            self.bundleID = bundleID
            self.spokenName = spokenName
        }

        init?(_ app: NSRunningApplication) {
            guard let bundleID = app.bundleIdentifier else { return nil }
            self.init(bundleID: bundleID, spokenName: app.localizedName)
        }
    }

    let bundleID: String
    let matchPrefix: String
    let spokenName: String

    init(bundleID: String, matchPrefix: String? = nil, spokenName: String?) {
        self.bundleID = bundleID
        self.matchPrefix = matchPrefix ?? bundleID
        self.spokenName = spokenName.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
    }

    /// EXACT FIRST, THEN THE FAMILY — the same two-tier question
    /// `ApplicationRegistration.owns(bundleID:)` answers for ambient routing
    /// and `VerifiedActivation.regularApplication` answers for activation,
    /// asked here through the identical boundary predicate,
    /// `ApplicationRegistration.isInFamily`.
    ///
    /// THE INCIDENT THIS FIXES: a taught application's `TypingSurface` used
    /// to carry `matchPrefix == bundleID` — the package's exact DECLARED id
    /// — and this property compared it exactly against every running
    /// process. `scrivener.mary` declares `com.literatureandlatte.scrivener`;
    /// the real, installed Scrivener 3 runs as
    /// `com.literatureandlatte.scrivener3`. An explicit `app: "Scrivener"`
    /// argument to `type_at_cursor` resolves through `taughtSurface(named:)`
    /// below, which used to hand this property the declared id with no
    /// family — so it answered false against a genuinely running Scrivener
    /// and misfired "Open Scrivener first". `taughtSurface(named:)` now
    /// carries the package's declared `bundleIdentifierPrefix` as
    /// `matchPrefix`, and this reads it with the SAME family rule ambient
    /// routing already trusts — one mechanism, not a second one invented
    /// here. The frontmost rung (no explicit `app`) was never routed through
    /// `taughtSurface`, so it was already unaffected and stays that way.
    var isRunning: Bool {
        Self.isRunning(
            bundleID: bundleID,
            matchPrefix: matchPrefix,
            runningBundleIdentifiers: NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier))
    }

    /// The pure decision, pulled out of the live-process read above so the
    /// exact-then-family rule is testable without a live process of either
    /// vintage actually running.
    static func isRunning(
        bundleID: String,
        matchPrefix: String,
        runningBundleIdentifiers: [String]
    ) -> Bool {
        let bundleID = bundleID.lowercased()
        let matchPrefix = matchPrefix.lowercased()
        if runningBundleIdentifiers.contains(where: { $0.lowercased() == bundleID }) {
            return true
        }
        return runningBundleIdentifiers.contains {
            ApplicationRegistration.isInFamily($0.lowercased(), prefix: matchPrefix)
        }
    }

    /// `type_at_cursor` must never turn an ordinary writing request into a
    /// shell command or code edit. The app-specific code path owns Xcode;
    /// terminals stay intentionally outside the generic keyboard surface.
    static func canReceiveProse(bundleID: String) -> Bool {
        SelectionSurfacePolicy.permitsProseApplication(bundleID)
    }

    /// Resolves a real app, in safety order:
    ///
    /// 1. a taught writing application the user NAMED (which Mary may
    ///    activate — the only rung that may reach an app that is not already
    ///    frontmost);
    /// 2. an explicit other name that identifies exactly one running app;
    /// 3. the surface a binding JUST STAGED for this work (a fresh document,
    ///    a raised window) — verified staging outranks turn-start attention;
    /// 4. the exact app that owns a fresh generic selection;
    /// 5. the frontmost ordinary text surface;
    /// and nothing else — see the refusal at the end.
    ///
    /// An unknown explicit name is accepted only when it exactly identifies
    /// one running application. That lets "write this in Notes" return to
    /// Notes after the request surface has focus, without silently choosing
    /// among multiple possible apps. A name that matches NO running app
    /// ("Untitled", "the new document" — a title, not an app) falls to the
    /// staged surface when one is fresh: that is the document the model is
    /// talking about.
    ///
    /// RUNG 3 IS THE INCIDENT FIX: `preferredApplicationID` is routed
    /// attention computed at TURN START — before `new_pages_document` ran —
    /// so create → type used to chase a stale pre-turn highlight while the
    /// fresh document sat empty.
    static func resolve(
        requested: String?,
        preferredApplicationID: String?,
        frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        runningApplications suppliedApplications: [RunningApplication]? = nil,
        staged: StagedWritingSurface.Staged? = StagedWritingSurface.shared.fresh()
    ) -> TypingSurface? {
        let applications = suppliedApplications ?? NSWorkspace.shared.runningApplications
            .compactMap(RunningApplication.init)
        let frontmostApplication = frontmost.flatMap(RunningApplication.init)
        let stagedSurface: TypingSurface? = staged.flatMap { staged in
            guard canReceiveProse(bundleID: staged.bundleID),
                  let app = applications.first(where: { $0.bundleID == staged.bundleID })
            else { return nil }
            return TypingSurface(
                bundleID: staged.bundleID, spokenName: staged.spokenName ?? app.spokenName)
        }
        // THE SAME RUNG, FOR AN APPLICATION BONNIE WAS TAUGHT — and it has to
        // be HERE, above the running-applications rung, because this is the
        // only rung that may name an app Mary will ACTIVATE. Every rung
        // below requires the application to be running already, so without
        // this a taught manuscript application could receive dictation only
        // while it was literally frontmost, and "write this in <app>" with the
        // app in the background refused.
        //
        // Gated on EYES and the WRITING discipline, the same two halves
        // `SelectionSurfacePolicy.isKnownProseEditor` uses: a package that
        // merely declares aliases must not be able to talk its way into
        // having a paragraph typed into it.
        if let requested, let taught = taughtSurface(named: requested) {
            return taught
        }

        if let requested {
            let matches = applications.filter { app in
                canReceiveProse(bundleID: app.bundleID) && names(app, requested: requested)
            }
            if matches.count == 1, let app = matches.first {
                return TypingSurface(bundleID: app.bundleID, spokenName: app.spokenName)
            }
            // Zero matches + a fresh staged surface: the "app" was a document
            // title. Ambiguity (two matches) still refuses — never guess.
            if matches.isEmpty, let stagedSurface { return stagedSurface }
            return nil
        }

        if let stagedSurface { return stagedSurface }

        if let preferredApplicationID,
           canReceiveProse(bundleID: preferredApplicationID),
           let app = applications.first(where: { $0.bundleID == preferredApplicationID }) {
            return TypingSurface(bundleID: preferredApplicationID, spokenName: app.spokenName)
        }

        if let frontmostApplication,
           canReceiveProse(bundleID: frontmostApplication.bundleID) {
            return TypingSurface(
                bundleID: frontmostApplication.bundleID, spokenName: frontmostApplication.spokenName)
        }

        // NO ONE-KNOWN-APP FALLBACK. Bonnie ended this ladder with "exactly
        // one typing app is running, so it must be that one" — a sound guess
        // over a closed set of two, already narrowed in its own comment once
        // the set grew to three. Over an open roster it is not a guess but a
        // coin toss, and what a coin toss decides here is which of the user's
        // documents gets typed into. Refusing is the answer: nothing is
        // frontmost, nothing was staged, nothing was named.
        return nil
    }

    /// A TAUGHT WRITING APPLICATION THE USER JUST NAMED, as a surface Mary
    /// may bring forward. Nil unless the roster knows the name, the
    /// registration earned eyes, it realizes writing, and it declares an exact
    /// bundle id — a FAMILY prefix cannot be activated, only matched.
    static func taughtSurface(named requested: String) -> TypingSurface? {
        let asked = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return nil }
        let roster = AmbientApplicationIndexProvider.current
        let registration = roster.registration(id: asked)
            ?? roster.all.first { $0.profile.isMentioned(in: asked) }
        guard let registration,
              registration.hasEyes,
              registration.place.focus == .writing,
              let bundleID = registration.bundleIdentifiers.sorted().first
        else { return nil }
        // THE FAMILY, CARRIED THROUGH — not just the exact declared id. See
        // `isRunning`'s header: this is what lets it recognize a running
        // process one major version ahead of what the package declared.
        return TypingSurface(
            bundleID: bundleID,
            matchPrefix: registration.bundleIdentifierPrefix ?? bundleID,
            spokenName: registration.displayName)
    }

    private static func names(_ app: RunningApplication, requested: String) -> Bool {
        let requested = normalized(requested)
        guard !requested.isEmpty else { return false }
        return [app.spokenName, app.bundleID]
            .compactMap { $0 }
            .map(normalized)
            .contains(requested)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
