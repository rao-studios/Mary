//
//  AmbientPlaceTests.swift
//  MaryAmbientTests
//
//  WHAT: Realm semantics + token ABI + browser carve-out + container keying.
//  OUT:  AmbientPlace / AmbientPlaceResolver / ContainerRegistry
//  PIN:  native tokens = world raw values; browsing registration joins the browser workspace
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientPlaceTests {

    /// SCOPED, never installed. These suites run concurrently with everything
    /// else in the package, and installing on the process-wide provider would
    /// answer this question for whatever else happens to be mid-turn — the
    /// flake this file hit on its first run.
    private func withRoster<T>(
        _ registrations: [ApplicationRegistration], _ body: () -> T
    ) -> T {
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster(registrations), operation: body)
    }

    private func sketch(
        placeClass: AmbientPlaceClass = .dataSource,
        perception: ApplicationPerception? = nil
    ) -> ApplicationRegistration {
        ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            placeClass: placeClass,
            perception: perception)
    }

    /// A BUILT-IN PLACE IS ITS WORLD, in every member. This is the property
    /// that makes the whole change invisible to the twenty-two worlds that
    /// existed before it.
    @Test func aBuiltInPlaceAnswersExactlyAsItsWorld() {
        withRoster([]) {
            for world in AmbientAttention.allCases {
                let place = AmbientPlace.lane(world)
                #expect(place.token == world.rawValue)
                #expect(place.placeClass == world.placeClass)
                #expect(place.hasEyes == world.hasEyes)
                #expect(place.displayName == world.displayName)
                #expect(place.order == world.order)
            }
        }
    }

    /// A REGISTERED PLACE ANSWERS FOR ITSELF, not for the host world it rides.
    /// `.applications` is `.perceptionOnly` and named "Other apps"; reading either
    /// off the host is what would deny a registration its own identity.
    @Test func aRegisteredPlaceAnswersForItselfNotItsHost() {
        let registration = sketch(
            placeClass: .workspace,
            perception: .init(documentOperation: "read_canvas", pollSeconds: 30))
        withRoster([registration]) {
            let place = AmbientPlace(attention: .applications, application: "sketch")
            #expect(place.token == "applications:sketch")
            #expect(place.displayName == "Sketch", "not \"Other apps\"")
            #expect(place.placeClass == .workspace, "not the host's .perceptionOnly")
            #expect(place.hasEyes)
            #expect(AmbientAttention.applications.hasEyes == false, "the host is unchanged")
        }
    }

    /// EYES ARE EARNED, NOT DECLARED. A package may class itself workspace and
    /// supply no way to be observed; the honest answer is "recognized, not
    /// watched", because a card claiming live sight of a document nothing polls
    /// is the confident lie this layer refuses.
    @Test func aWorkspaceClassRegistrationWithNoContractHasNoEyes() {
        withRoster([sketch(placeClass: .workspace, perception: nil)]) {
            let place = AmbientPlace(attention: .applications, application: "sketch")
            #expect(place.placeClass == .workspace)
            #expect(!place.hasEyes, "declared workspace, declared no observation")
            #expect(!Passage.canHold(place), "and therefore holds no passages")
        }
    }

    /// REGISTRATIONS SORT AFTER EVERY BUILT-IN, so importing a package cannot
    /// reorder the worlds the golden prompt diff compares byte for byte.
    @Test func registrationsSortAfterEveryBuiltInWorld() {
        withRoster([sketch()]) {
            let registered = AmbientPlace(attention: .applications, application: "sketch")
            for world in AmbientAttention.allCases {
                #expect(AmbientPlace.lane(world).order < registered.order)
            }
        }
    }

    /// AN UNREGISTERED APPLICATION FALLS BACK TO ITS HOST rather than
    /// inventing a taxonomy. This is the state before configuration and after
    /// a package is removed, and it must degrade rather than crash.
    @Test func anUnknownApplicationFallsBackToItsHostWorld() {
        withRoster([]) {
            let place = AmbientPlace(attention: .applications, application: "ghost")
            #expect(place.registration == nil)
            #expect(place.placeClass == AmbientAttention.applications.placeClass)
            #expect(place.displayName == AmbientAttention.applications.displayName)
            #expect(!place.hasEyes)
            // The key still discriminates, so its facts do not collide with
            // another application's even though nothing knows what it is.
            #expect(place.token == "applications:ghost")
        }
    }

    /// THE POLL CADENCE IS CLAMPED, not trusted. A package asking to be polled
    /// every second would turn a subprocess against the vendor's own tooling
    /// into a background load the user can feel.
    @Test func thePollCadenceIsClampedToItsBounds() {
        #expect(ApplicationPerception(documentOperation: "r", pollSeconds: 1).pollSeconds
                == ApplicationPerception.pollBounds.lowerBound)
        #expect(ApplicationPerception(documentOperation: "r", pollSeconds: 9_000).pollSeconds
                == ApplicationPerception.pollBounds.upperBound)
        #expect(ApplicationPerception(documentOperation: "r", pollSeconds: 30).pollSeconds == 30)
    }

    @Test func nativeAndDynamicTokensAreStructurallyDisjoint() {
        let nativeTokens = Set(AmbientAttention.allCases.map { AmbientPlace.lane($0).token })
        for world in AmbientAttention.allCases {
            #expect(!world.rawValue.contains(":"))
            let dynamicTwin = AmbientPlace.application(world.rawValue)
            #expect(!nativeTokens.contains(dynamicTwin.token))
            #expect(AmbientPlace.from(token: world.rawValue) == .lane(world))
            #expect(AmbientPlace.from(token: dynamicTwin.token) == dynamicTwin)
        }
    }

    @Test func registeredChromeStaysInTheBrowserRealm() {
        let chrome = ApplicationRegistration(
            id: "chrome",
            profile: ApplicationProfile(
                id: "chrome", title: "Google Chrome", summary: "Browser.",
                abilities: [.browsing]),
            bundleIdentifiers: ["com.google.Chrome"],
            placeClass: .workspace,
            displayName: "Chrome")
        withRoster([chrome]) {
            #expect(AmbientPlaceResolver.factPlace(forBundleID: "com.google.Chrome")
                == AmbientPlaceResolver.browserPlace)
        }
    }

    /// THE BROWSER WORKSPACE IS BACKED BY A BROWSER'S REGISTRATION. No package
    /// registers under the id "browser", so the place answered nil for its
    /// registration and everything derived from one — class, eyes, craft —
    /// answered as though no browser were installed. It could never lead, and
    /// naming it did nothing.
    @Test func theBrowserWorkspaceIsBackedByABrowsingRegistration() {
        let chrome = ApplicationRegistration(
            id: "chrome",
            profile: ApplicationProfile(
                id: "chrome", title: "Google Chrome", summary: "Browser.",
                abilities: [.browsing]),
            bundleIdentifiers: ["com.google.Chrome"],
            placeClass: .workspace,
            displayName: "Chrome",
            perception: ApplicationPerception(
                kind: .workspace, documentOperation: "page_context", pollSeconds: 15))
        let sketch = sketch(placeClass: .dataSource)
        withRoster([sketch, chrome]) {
            let place = AmbientPlaceResolver.browserPlace
            #expect(place.registration?.id == "chrome")
            #expect(place.placeClass == .workspace)
            #expect(place.hasEyes)
            #expect(place.ability == .browsing)
        }
        // AND NOTHING ELSE BORROWS THE RULE: a place nobody registered stays unbacked.
        withRoster([chrome]) {
            #expect(AmbientPlace.application("sketch").registration == nil)
        }
        withRoster([sketch]) {
            #expect(AmbientPlaceResolver.browserPlace.registration == nil)
        }
    }

    @Test func aRegisteredApplicationMintsItsOwnHandles() {
        let registry = ContainerRegistry()
        let handle = registry.handle(
            place: .application("sketch"), prefix: "A", key: "canvas-1")
        #expect(!handle.isEmpty)
        #expect(registry.resolvePlace(handle)?.place == .application("sketch"))
        #expect(registry.handle(
            place: .application("sketch"), prefix: "A", key: "canvas-1") == handle)
    }

    @Test func aGlanceNeverTouchesTheLead() {
        let tracker = WorkspaceFocusTracker()
        tracker.record(bundleID: WorkspaceApplicationIdentity.xcode)
        tracker.noteGlance(place: AmbientPlaceResolver.browserPlace)
        let signal = tracker.signal()
        #expect(signal.lead == .application(WorkspaceApplicationIdentity.xcode))
        #expect(signal.coActive.contains(AmbientPlaceResolver.browserPlace))
    }
}
