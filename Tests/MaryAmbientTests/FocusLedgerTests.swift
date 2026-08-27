//
//  FocusLedgerTests.swift
//  BonnieAmbientTests
//
//  THE EVIDENCE LEDGER'S SPEC — the responder layer 6f9fe3c shipped
//  untested. What it pins: kind precedence in the co-active ranking
//  (activity > activation > glance), the 5-minute co-active and 10-minute
//  glance horizons, glance-never-leads, the concrete process behind the
//  browser realm (both horizons of `evidenceProcess`), and the termination
//  sweep that keeps a quit browser from speaking.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct FocusLedgerTests {

    private var browser: AmbientRealm { AmbientRealmResolver.browserRealm }

    /// CHROME IS A BROWSER BECAUSE A PACKAGE SAYS SO, which is why these
    /// tests now have to say so too. `chrome.mary` declares its bundle
    /// identifiers and realizes the `browsing` Ability; the ambient layer
    /// reads browser-ness off that registration rather than off a compiled
    /// list, so an unregistered Chrome is — correctly — just an application.
    /// Safari needs no roster: it is the one compiled browser.
    private func withChromeInstalled<T>(_ body: () -> T) -> T {
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "chrome",
                    profile: ApplicationProfile(
                        id: "chrome", title: "Google Chrome", summary: "Browser.",
                        abilities: [.browsing]),
                    bundleIdentifiers: ["com.google.Chrome"],
                    worldClass: .workspace,
                    displayName: "Chrome"),
            ]),
            operation: body)
    }

    @Test func aBrowserActivationLeadsAndStampsItsConcreteProcess() {
        withChromeInstalled {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            #expect(tracker.leadRealm() == browser)
            #expect(tracker.evidenceProcess(for: browser) == "com.google.Chrome")
            #expect(tracker.signal().lead == browser)
        }
    }

    @Test func aGlanceNeverTouchesTheLead() {
        let tracker = WorkspaceFocusTracker()
        // AN UNREGISTERED APPLICATION IS ITS BUNDLE ID. Nothing compiled
        // recognizes this app by name, and the terminal arm carries the one
        // identity there is — which is exactly how a generic application
        // still leads instead of producing no signal at all.
        tracker.record(bundleID: WorkspaceApplicationIdentity.xcode)
        tracker.noteGlance(realm: browser)
        let signal = tracker.signal()
        #expect(signal.lead == .dynamic(WorkspaceApplicationIdentity.xcode))
        #expect(signal.coActive.contains(browser))
        #expect(signal.glanced.contains(browser))
    }

    @Test func coActiveEvidenceDecaysOnItsFiveMinuteHorizon() {
        withChromeInstalled {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.google.Chrome")
            tracker.record(bundleID: WorkspaceApplicationIdentity.xcode)
            let now = Date()
            let inside = tracker.signal(at: now.addingTimeInterval(
                FocusSignal.coActiveHorizon - 5))
            #expect(inside.coActive.contains(browser))
            let outside = tracker.signal(at: now.addingTimeInterval(
                FocusSignal.coActiveHorizon + 5))
            #expect(!outside.coActive.contains(browser))
        }
    }

    @Test func aGlanceOutlivesCoActiveEvidenceOnItsOwnHorizon() {
        let tracker = WorkspaceFocusTracker()
        tracker.record(bundleID: WorkspaceApplicationIdentity.xcode)
        tracker.noteGlance(realm: browser)
        let now = Date()
        let between = tracker.signal(at: now.addingTimeInterval(
            FocusSignal.coActiveHorizon + 30))
        #expect(between.glanced.contains(browser))
        let past = tracker.signal(at: now.addingTimeInterval(
            FocusSignal.glanceHorizon + 5))
        #expect(!past.glanced.contains(browser))
    }

    @Test func activationOutranksAGlanceInTheCoActiveOrder() {
        withChromeInstalled {
            let tracker = WorkspaceFocusTracker()
            // A browser ACTIVATION and a FRESHER Pages glance: the ranking is
            // strongest-evidence-then-recency, so the activation must still
            // rank first among the co-actives.
            tracker.record(bundleID: "com.google.Chrome")
            tracker.noteGlance(realm: .dynamic("pages"))
            tracker.record(bundleID: WorkspaceApplicationIdentity.xcode)
            let signal = tracker.signal()
            #expect(signal.lead == .dynamic(WorkspaceApplicationIdentity.xcode))
            #expect(signal.coActive.first == browser)
            #expect(signal.glanced.contains(.dynamic("pages")))
        }
    }

    @Test func evidenceProcessAnswersAgainstAnExplicitHorizon() {
        withChromeInstalled {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.google.Chrome")
            let now = Date()
            let staleForCoActive = now.addingTimeInterval(FocusSignal.coActiveHorizon + 60)
            // Fresh horizon lapsed…
            #expect(tracker.evidenceProcess(for: browser, at: staleForCoActive) == nil)
            // …but the lead's own 20-minute bound still answers honestly.
            #expect(tracker.evidenceProcess(
                for: browser,
                within: WorkspaceFocusTracker.signalHorizon,
                at: staleForCoActive) == "com.google.Chrome")
            #expect(tracker.evidenceProcess(
                for: browser,
                within: WorkspaceFocusTracker.signalHorizon,
                at: now.addingTimeInterval(WorkspaceFocusTracker.signalHorizon + 60)) == nil)
        }
    }

    @Test func theTerminationSweepClearsTheBrowsersClaims() {
        withChromeInstalled {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.google.Chrome")
            #expect(tracker.leadRealm() == browser)
            tracker.clearLead(ifApplication: AmbientRealmResolver.browserApplicationID)
            #expect(tracker.leadRealm() == nil)
            #expect(tracker.evidenceProcess(for: browser) == nil)
        }
    }

    @Test func singleRealmSessionsKeepTheParityRule() {
        let tracker = WorkspaceFocusTracker()
        tracker.record(bundleID: "com.apple.Safari")
        let signal = tracker.signal()
        #expect(signal.lead == tracker.leadRealm())
        #expect(signal.coActive.isEmpty)
        #expect(signal.glanced.isEmpty)
    }
}
