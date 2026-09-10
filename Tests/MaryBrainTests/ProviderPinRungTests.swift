//
//  ProviderPinRungTests.swift
//  MaryBrainTests
//
//  WHAT: The pinned rung of the application-provider ladder, now that something
//        fills it.
//  OUT:  ApplicationProviderResolver + AbilityRuntime.pinnedApplicationID
//  PIN:  A RUNG THE SPEC DECLARES AND NOTHING FILLS IS A LADDER WITH A HOLE IN
//        IT. `named > interaction > pinned > focused > habit > staticPreference`
//        was the documented order, and `pinnedApplicationID` was hard-wired nil
//        with a comment saying no pinning surface existed — while
//        `WorkspaceFocusTracker.pin` had been the debugger's focus-correction
//        control the whole time. A pin is a CORRECTION, so the test that matters
//        is the one where it disagrees with the window in front.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct ProviderPinRungTests {

    private static func profile(_ id: String) -> ApplicationProfile {
        ApplicationProfile(id: id, summary: "A fixture.")
    }

    private static let profiles = [profile("safari"), profile("pages"), profile("xcode")]

    private static func decisive(
        named: Set<String> = [],
        interaction: String? = nil,
        pinned: String? = nil,
        focused: String? = nil
    ) -> (ids: Set<String>, selection: ProviderTurnSelection) {
        let selection = ApplicationProviderResolver.resolve(
            snapshot: .empty,
            signals: ApplicationProviderSignals(
                namedApplicationIDs: named,
                interactionApplicationID: interaction,
                pinnedApplicationID: pinned,
                focusedApplicationID: focused),
            profiles: profiles)
        return (selection.decisiveApplicationIDs, selection)
    }

    /// THE RUNG CARRIES, and it is the whole repair: a pin with nothing above it
    /// decides the turn's application.
    @Test func aPinDecidesWhenNothingStrongerSpoke() {
        #expect(Self.decisive(pinned: "safari").ids == ["safari"])
    }

    /// AND IT BEATS THE WINDOW IN FRONT. This is the reason the rung sits where
    /// it does: a pin the frontmost window could overrule is not a correction,
    /// it is a suggestion — and the person planted it precisely because the
    /// automatic answer was wrong.
    @Test func aPinOutranksTheFrontmostWindow() {
        #expect(Self.decisive(pinned: "safari", focused: "pages").ids == ["safari"])
    }

    /// BUT THE WORDS STILL WIN. Naming an application outright is the strongest
    /// statement there is, and a stale pin must never silently redirect it.
    @Test func namingAnApplicationOutranksThePin() {
        #expect(Self.decisive(named: ["pages"], pinned: "safari").ids == ["pages"])
    }

    /// AND SO DOES THE PACKET THE TURN ACCEPTED — a highlight the route admitted
    /// as its referent is an interaction, which the ladder puts above a pin.
    @Test func anAcceptedInteractionOutranksThePin() {
        #expect(Self.decisive(interaction: "pages", pinned: "safari").ids == ["pages"])
    }

    /// A PIN NAMING SOMETHING NO PROFILE KNOWS ASSERTS NOTHING. The rung resolves
    /// through the registry like every other; an unresolvable pin must fall
    /// through rather than assert a provider nothing can serve.
    @Test func aPinNoProfileKnowsIsNotAsserted() {
        let resolved = Self.decisive(pinned: "sketch", focused: "pages")
        #expect(resolved.ids == ["pages"])
        #expect(!resolved.selection.assertedApplicationIDs.contains("sketch"))
    }

    /// An adapter is the cheapest source of a registered profile — its own
    /// `applicationProfile` carries its name as the logical id.
    private struct NamedAdapter: MaryAdapter {
        let name: String
        let summary = "A fixture."
        var skillBindings: [SkillBinding] { [] }
    }

    /// THE RUNTIME'S HALF: the injected provider is resolved through the profiles
    /// before it reaches the ladder, so a pin spelled differently still lands.
    @Test func theRuntimeResolvesThePinThroughItsProfiles() {
        let runtime = AbilityRuntime(
            plugins: [NamedAdapter(name: "safari")],
            pinnedProvider: { "SAFARI" },
            world: AmbientWorld(store: AmbientContextStore()),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        #expect(runtime.pinnedApplicationID == "safari")
    }

    /// A PIN NO PROFILE KNOWS REACHES THE LADDER AS NOTHING, from the runtime's
    /// side too — the guard is not only the resolver's.
    @Test func theRuntimeDropsAPinNoProfileKnows() {
        let runtime = AbilityRuntime(
            plugins: [NamedAdapter(name: "safari")],
            pinnedProvider: { "sketch" },
            world: AmbientWorld(store: AmbientContextStore()),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        #expect(runtime.pinnedApplicationID == nil)
    }

    /// AND NO PIN IS NO ASSERTION — the default every turn has had until now.
    @Test func noPinAssertsNothing() {
        let runtime = AbilityRuntime(
            plugins: [NamedAdapter(name: "safari")],
            world: AmbientWorld(store: AmbientContextStore()),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        #expect(runtime.pinnedApplicationID == nil)
    }
}
