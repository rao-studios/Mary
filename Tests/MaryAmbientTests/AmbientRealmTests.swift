//
//  AmbientRealmTests.swift
//  BonnieAmbientTests
//
//  THE REALM'S SEMANTICS SPEC — five properties, one per test: a native realm
//  answers exactly as its world always did; a dynamic realm answers for
//  itself, not the host lane it rides; registrations sort after every native;
//  an unknown application falls back to its host world rather than inventing
//  a taxonomy; and a workspace-class registration with no perception contract
//  has no eyes. (Plus the poll-cadence clamp the perception contract rides
//  in on.)
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientRealmTests {

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
        worldClass: AmbientWorldClass = .dataSource,
        perception: ApplicationPerception? = nil
    ) -> ApplicationRegistration {
        ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            worldClass: worldClass,
            perception: perception)
    }

    /// A BUILT-IN PLACE IS ITS WORLD, in every member. This is the property
    /// that makes the whole change invisible to the twenty-two worlds that
    /// existed before it.
    @Test func aBuiltInPlaceAnswersExactlyAsItsWorld() {
        withRoster([]) {
            for world in AmbientWorld.allCases {
                let place = AmbientRealm.world(world)
                #expect(place.token == world.rawValue)
                #expect(place.worldClass == world.worldClass)
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
            worldClass: .workspace,
            perception: .init(documentOperation: "read_canvas", pollSeconds: 30))
        withRoster([registration]) {
            let place = AmbientRealm(world: .applications, application: "sketch")
            #expect(place.token == "applications:sketch")
            #expect(place.displayName == "Sketch", "not \"Other apps\"")
            #expect(place.worldClass == .workspace, "not the host's .perceptionOnly")
            #expect(place.hasEyes)
            #expect(AmbientWorld.applications.hasEyes == false, "the host is unchanged")
        }
    }

    /// EYES ARE EARNED, NOT DECLARED. A package may class itself workspace and
    /// supply no way to be observed; the honest answer is "recognized, not
    /// watched", because a card claiming live sight of a document nothing polls
    /// is the confident lie this layer refuses.
    @Test func aWorkspaceClassRegistrationWithNoContractHasNoEyes() {
        withRoster([sketch(worldClass: .workspace, perception: nil)]) {
            let place = AmbientRealm(world: .applications, application: "sketch")
            #expect(place.worldClass == .workspace)
            #expect(!place.hasEyes, "declared workspace, declared no observation")
            #expect(!Passage.canHold(place), "and therefore holds no passages")
        }
    }

    /// REGISTRATIONS SORT AFTER EVERY BUILT-IN, so importing a package cannot
    /// reorder the worlds the golden prompt diff compares byte for byte.
    @Test func registrationsSortAfterEveryBuiltInWorld() {
        withRoster([sketch()]) {
            let registered = AmbientRealm(world: .applications, application: "sketch")
            for world in AmbientWorld.allCases {
                #expect(AmbientRealm.world(world).order < registered.order)
            }
        }
    }

    /// AN UNREGISTERED APPLICATION FALLS BACK TO ITS HOST rather than
    /// inventing a taxonomy. This is the state before configuration and after
    /// a package is removed, and it must degrade rather than crash.
    @Test func anUnknownApplicationFallsBackToItsHostWorld() {
        withRoster([]) {
            let place = AmbientRealm(world: .applications, application: "ghost")
            #expect(place.registration == nil)
            #expect(place.worldClass == AmbientWorld.applications.worldClass)
            #expect(place.displayName == AmbientWorld.applications.displayName)
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
}
