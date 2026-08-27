//
//  BrowserPlaceCarveOutTests.swift
//  BonnieAmbientTests
//
//  THE BROWSER CARVE-OUT SPEC. A dynamic package may REGISTER a browser
//  bundle (chrome.mary claims com.google.Chrome so its operations can
//  drive Chrome), but the browser is ONE workspace regardless of which
//  plugin drives it. These tests pin the three places that keep that true:
//  the resolver ladder, the registration's `place`, and the tracker's
//  record ladder. Without the carve-out, installing chrome.mary would
//  silently re-home Chrome's facts, ledger evidence, and deposited memory
//  into `.application("chrome")`, splitting the browser lane by engine.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct BrowserPlaceCarveOutTests {

    /// SCOPED, never installed — same reasoning as AmbientPlaceTests: these
    /// suites run concurrently, and the process-wide provider would answer
    /// this question for whatever else is mid-turn.
    private func withRoster<T>(
        _ registrations: [ApplicationRegistration], _ body: () -> T
    ) -> T {
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster(registrations), operation: body)
    }

    /// THE DECLARATION IS WHAT MAKES IT A BROWSER. `abilities: [.browsing]`
    /// is not decoration here — the ambient layer no longer carries a
    /// compiled list of browser bundles, so a registration that realizes the
    /// `browsing` Ability is precisely what joins the browser workspace. This
    /// fixture mirrors what `chrome.mary` actually compiles to: its own
    /// bundle identifiers, plus `browsing` picked up from the skills it
    /// realizes.
    private var chrome: ApplicationRegistration {
        ApplicationRegistration(
            id: "chrome",
            profile: ApplicationProfile(
                id: "chrome", title: "Google Chrome", summary: "Browser.",
                abilities: [.browsing]),
            bundleIdentifiers: ["com.google.Chrome"],
            worldClass: .workspace,
            displayName: "Chrome")
    }

    /// The counter-case that proves the rule: a registration claiming a
    /// browser-shaped bundle WITHOUT realizing browsing is not a browser, and
    /// keeps its own place. Before browser-ness was declared, a hardcoded
    /// prefix would have swallowed it.
    private var browserShapedImposter: ApplicationRegistration {
        ApplicationRegistration(
            id: "notabrowser",
            profile: ApplicationProfile(
                id: "notabrowser", title: "Not A Browser", summary: "Nope."),
            bundleIdentifiers: ["com.google.Chrome.helper.fake"],
            worldClass: .workspace)
    }

    private var sketch: ApplicationRegistration {
        ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(
                id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            worldClass: .workspace)
    }

    /// A REGISTERED BROWSER BUNDLE STILL RESOLVES TO THE BROWSER WORKSPACE.
    /// The browser rung sits above the registration rung; registration
    /// grants verbs, it never re-homes the workspace.
    @Test func registeredChromeStaysInTheBrowserRealm() {
        withRoster([chrome]) {
            #expect(AmbientPlaceResolver.factPlace(forBundleID: "com.google.Chrome")
                == AmbientPlaceResolver.browserPlace)
            #expect(AmbientPlaceResolver.applicationPlace(forBundleID: "com.google.Chrome")
                == AmbientPlaceResolver.browserPlace)
        }
    }

    /// PREFIX FAMILIES RIDE THE SAME CARVE-OUT — Chrome Canary/Beta resolve
    /// to the browser workspace even though only the exact bundle registered.
    @Test func chromeVariantsStayInTheBrowserRealm() {
        withRoster([chrome]) {
            #expect(AmbientPlaceResolver.factPlace(forBundleID: "com.google.Chrome.canary")
                == AmbientPlaceResolver.browserPlace)
        }
    }

    /// A NON-BROWSER DYNAMIC APP IS UNTOUCHED by the carve-out: Sketch keeps
    /// its own place exactly as before.
    @Test func nonBrowserRegistrationsKeepTheirOwnPlace() {
        withRoster([chrome, sketch]) {
            let place = AmbientPlaceResolver.factPlace(
                forBundleID: "com.bohemiancoding.sketch3")
            #expect(place == AmbientPlace(world: .applications, application: "sketch"))
        }
    }

    /// THE REGISTRATION'S OWN `place` AGREES: a browser-only dynamic profile
    /// files on the browser workspace, so facts and elements published under
    /// the registration land on the one shared lane.
    /// Scoped, because `place` now asks the ROSTER whether its bundles are
    /// browsers rather than a compiled list — the registration answers for
    /// itself only once it is installed, which is the same order the runtime
    /// sees.
    @Test func browserOnlyRegistrationPlaceIsTheBrowserRealm() {
        withRoster([chrome, sketch]) {
            #expect(chrome.place == AmbientPlaceResolver.browserPlace)
            #expect(sketch.place
                == AmbientPlace(world: .applications, application: "sketch"))
        }
    }

    /// A MIXED PROFILE (browser + non-browser bundles) does NOT ride the
    /// carve-out — the shortcut is only honest when every process identity
    /// is a browser.
    @Test func mixedBundleRegistrationKeepsItsOwnRealm() {
        let mixed = ApplicationRegistration(
            id: "hybrid",
            profile: ApplicationProfile(
                id: "hybrid", title: "Hybrid", summary: "Test."),
            bundleIdentifiers: ["com.google.Chrome", "com.example.tool"],
            worldClass: .workspace)
        #expect(mixed.place
            == AmbientPlace(world: .applications, application: "hybrid"))
    }

    /// THE TRACKER'S LADDER: a Chrome activation with chrome.mary
    /// installed still stamps the browser workspace — lead AND ledger, with
    /// the concrete process behind the logical place — never
    /// noteDynamicApplication("chrome").
    @Test func chromeActivationLeadsTheBrowserWorkspaceEvenWhenRegistered() {
        withRoster([chrome]) {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            #expect(tracker.leadPlace() == AmbientPlaceResolver.browserPlace)
            #expect(tracker.evidenceProcess(for: AmbientPlaceResolver.browserPlace)
                == "com.google.Chrome")
        }
    }

    /// AND A REGISTERED NON-BROWSER APP STILL TAKES THE REGISTRATION ARM —
    /// the reorder moved the browser rung up, it did not swallow the
    /// dynamic-application arm.
    @Test func sketchActivationStillLeadsItsOwnRealm() {
        withRoster([sketch]) {
            let tracker = WorkspaceFocusTracker()
            tracker.record(bundleID: "com.bohemiancoding.sketch3", localizedName: "Sketch")
            #expect(tracker.leadPlace()
                == AmbientPlace(world: .applications, application: "sketch"))
        }
    }

    /// BROWSER-NESS IS DECLARED, NOT PATTERN-MATCHED. Chrome joins the
    /// browser workspace because its package realizes `browsing`; the same
    /// bundle family with no such declaration does not.
    @Test func onlyADeclaredBrowsingRegistrationJoinsTheBrowserWorkspace() {
        withRoster([browserShapedImposter]) {
            #expect(!AmbientPlaceResolver.isBrowser(
                bundleID: "com.google.Chrome.helper.fake"))
            #expect(AmbientPlaceResolver.factPlace(
                forBundleID: "com.google.Chrome.helper.fake")
                != AmbientPlaceResolver.browserPlace)
        }
        withRoster([chrome]) {
            #expect(AmbientPlaceResolver.isBrowser(bundleID: "com.google.Chrome"))
            #expect(AmbientPlaceResolver.browserName(
                bundleID: "com.google.Chrome") == "Chrome")
        }
    }

    /// SAFARI NEEDS NO PACKAGE. It is the one compiled browser and carries a
    /// closed `AmbientWorld` case, so it answers with an empty roster — which
    /// is also what a machine that has installed nothing looks like.
    @Test func safariIsABrowserWithNoRegistrationsAtAll() {
        withRoster([]) {
            #expect(AmbientPlaceResolver.isBrowser(
                bundleID: WorkspaceApplicationIdentity.safari))
            #expect(AmbientPlaceResolver.browserName(
                bundleID: WorkspaceApplicationIdentity.safari) == "Safari")
            // And an uninstalled Chrome is simply not a browser yet.
            #expect(!AmbientPlaceResolver.isBrowser(bundleID: "com.google.Chrome"))
        }
    }
}
