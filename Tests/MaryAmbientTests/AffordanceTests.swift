//
//  AffordanceTests.swift
//  BonnieAmbientTests
//
//  THE SPEC FOR "the screen is offering something that would do that".
//
//  The cases are the live incident and its neighbours: "Can you skip the ad"
//  over a page whose button says "Skip Ads", "Can you make it full screen"
//  over one labelled "Full screen (f)", and the near-misses that must NOT
//  resolve — a shared "the", a control that is only a landmark, a slate that
//  has gone stale.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AffordanceRuleTests {

    private let scope = AmbientElementScope.affordances(in: .lane(.applications))

    private func affordance(
        _ label: String,
        _ role: String = "button",
        enabled: Bool = true,
        help: String? = nil
    ) -> AmbientAffordance {
        AmbientAffordance(
            id: "\(role)|\(label.lowercased())", label: label,
            roleWord: role, ordinal: 1, isEnabled: enabled, help: help)
    }

    @Test func aButtonSerializesItsOwnWordsAndNothingElse() {
        let records = AffordanceRule.records(
            for: [affordance("Skip Ads", help: "Skip this advertisement")],
            scope: scope)
        let record = try! #require(records.first)
        #expect(record.kindWord == "button")
        #expect(record.name == "Skip Ads")
        #expect(record.capabilities.contains(.pressable))
        // The claims are the label, the role, the two joined, and the help
        // text. NOTHING derived from an intent vocabulary — no "skip",
        // no "advertisement" mapping, no site table.
        #expect(record.embedTexts.contains("skip ads"))
        #expect(record.embedTexts.contains("button"))
        #expect(record.embedTexts.contains("button labelled skip ads"))
        #expect(record.embedTexts.contains("skip this advertisement"))
    }

    @Test func anUnlabelledControlIsNeverHeld() {
        // Nothing to mean it with. Holding it would let a goal land on a
        // nameless icon by similarity to its role alone.
        #expect(AffordanceRule.records(
            for: [affordance("   ")], scope: scope).isEmpty)
    }

    @Test func aDisabledControlIsPerceivedButNotOffered() {
        let record = try! #require(AffordanceRule.records(
            for: [affordance("Continue", enabled: false)], scope: scope).first)
        #expect(record.name == "Continue")
        #expect(record.capabilities.isEmpty,
                "a disabled control must never satisfy `requires: .pressable`")
    }

    @Test func rolesDecideCapabilitiesAndAHeadingIsNotPressable() {
        #expect(AffordanceRule.capabilities(forRoleWord: "button") == [.pressable])
        #expect(AffordanceRule.capabilities(forRoleWord: "link") == [.pressable])
        #expect(AffordanceRule.capabilities(forRoleWord: "video") == [.pressable])
        #expect(AffordanceRule.capabilities(forRoleWord: "field")
                == [.pressable, .fillable])
        // A landmark, not an affordance — `scroll_to_on_page` reaches it, a
        // press never should.
        #expect(AffordanceRule.capabilities(forRoleWord: "heading").isEmpty)
    }

    @Test func theScopeKeyIsWhatMarksAnAffordancePartition() {
        #expect(scope.key.hasSuffix(AmbientElementScope.affordanceSuffix))
        // And it can never collide with the place's other slates — the whole
        // reason `.pressable` is safe to add.
        #expect(scope.key != AmbientPlaceResolver.browserApplicationID)
    }
}

@Suite struct AffordanceDistinctivenessTests {

    private func entry(
        name: String, basis: RankedAmbientElement.Basis, score: Float = 0.92
    ) -> RankedAmbientElement {
        RankedAmbientElement(
            record: AmbientElementRecord(
                scope: .affordances(in: .lane(.applications)),
                elementID: name, kindWord: "button", name: name,
                embedTexts: [name.lowercased()],
                capabilities: [.pressable], displaySummary: name),
            score: score, basis: basis)
    }

    @Test func aRealSharedWordCarriesAFlooredMatch() {
        #expect(AffordanceDistinctiveness.survives(
            entry(name: "Skip Ads", basis: .lexicalName),
            phrase: "can you skip the ad"))
    }

    @Test func aSharedStopWordDoesNot() {
        // The hazard the gate's word-level name floor creates: "the" is
        // shared, and without this guard a button called "The Defiance Act"
        // would floor at 0.92 on "skip the ad".
        #expect(!AffordanceDistinctiveness.survives(
            entry(name: "The Defiance Act", basis: .lexicalName),
            phrase: "can you skip the ad"))
    }

    @Test func aShortSharedWordDoesNot() {
        // "Ad" is three characters below the bar on purpose — `AmbientAddressProbe`'s
        // G3 value, for its reason: "Home" and "New Tab" must never address.
        #expect(!AffordanceDistinctiveness.survives(
            entry(name: "Ad Choices", basis: .lexicalName),
            phrase: "the ad"))
    }

    @Test func aSemanticScoreStandsOnItsOwn() {
        // The embedding compared whole claims; there is no floor to justify.
        #expect(AffordanceDistinctiveness.survives(
            entry(name: "Dismiss", basis: .semantic, score: 0.61),
            phrase: "get rid of that banner"))
    }
}

@Suite struct AffordanceProbeTests {

    private func store() -> AmbientElementIndexStore {
        // A private store: the probe ranks across every fresh affordance
        // slate, so a suite sharing `.shared` would rank another test's page.
        AmbientElementIndexStore()
    }

    private func publish(
        _ labels: [String], into scope: AmbientElementScope,
        store: AmbientElementIndexStore
    ) {
        store.noteElements(
            AffordanceRule.records(
                for: labels.enumerated().map { index, label in
                    AmbientAffordance(
                        id: "button|\(label.lowercased())", label: label,
                        roleWord: "button", ordinal: index + 1)
                },
                scope: scope),
            scope: scope)
    }

    @Test func aGoalReachesTheControlThatServesIt() {
        let store = store()
        let scope = AmbientElementScope.affordances(in: .lane(.applications))
        publish(["Skip Ads", "Subscribe", "Share"], into: scope, store: store)
        let offer = try! #require(
            AffordanceProbe.candidate(for: "can you skip the ad", store: store))
        #expect(offer.labels.first == "Skip Ads")
        #expect(offer.scope == scope)
    }

    @Test func fullScreenReachesThePlayersOwnControl() {
        let store = store()
        let scope = AmbientElementScope.affordances(in: .lane(.applications))
        publish(["Full screen (f)", "Settings", "Mute (m)"],
                into: scope, store: store)
        let offer = try! #require(
            AffordanceProbe.candidate(for: "can you make it full screen", store: store))
        #expect(offer.labels.first == "Full screen (f)")
    }

    @Test func aPhraseThatMatchesNothingOffersNothing() {
        let store = store()
        publish(["Subscribe", "Share"],
                into: .affordances(in: .lane(.applications)), store: store)
        // Nothing here would rename a file, and the honest failure must be
        // allowed to stand.
        #expect(AffordanceProbe.candidate(
            for: "rename the chapter to Prologue", store: store) == nil)
    }

    @Test func onlyAffordanceSlatesAreProbed() {
        let store = store()
        // A tab roster, in the browser place's OTHER partition. It carries no
        // `.pressable` capability and lives under a different key; a goal must
        // never rank it.
        let tabs = AmbientElementScope(
            place: AmbientPlaceResolver.browserPlace,
            key: AmbientPlaceResolver.browserApplicationID)
        store.noteElements(
            [AmbientElementRecord(
                scope: tabs, elementID: "tab:1", kindWord: "tab",
                name: "Skip Ads — the definitive guide",
                embedTexts: ["skip ads the definitive guide", "tab"],
                capabilities: [.prose], displaySummary: "Skip Ads")],
            scope: tabs)
        #expect(AffordanceProbe.candidate(
            for: "can you skip the ad", store: store) == nil)
    }

    @Test func aStaleSlateStopsDescribingTheScreen() {
        let store = store()
        publish(["Skip Ads"],
                into: .affordances(in: .lane(.applications)), store: store)
        // A button is pressable for five seconds; a slate older than the
        // horizon is a memory, not an offer.
        let later = Date().addingTimeInterval(
            AffordanceProbe.freshnessHorizon + 1)
        #expect(AffordanceProbe.candidate(
            for: "can you skip the ad", store: store, at: later) == nil)
    }

    @Test func aRetractedSlateOffersNothing() {
        let store = store()
        let scope = AmbientElementScope.affordances(in: .lane(.applications))
        publish(["Skip Ads"], into: scope, store: store)
        store.noteElements([], scope: scope)
        #expect(AffordanceProbe.candidate(
            for: "can you skip the ad", store: store) == nil)
    }

    @Test func aTiedGoalNamesItsRivals() {
        let store = store()
        publish(["Skip Ads", "Skip Intro"],
                into: .affordances(in: .lane(.applications)), store: store)
        let offer = try! #require(
            AffordanceProbe.candidate(for: "skip that", store: store))
        // Both are named. The nudge lists them and the act refuses by name —
        // pressing one on a coin toss is the thing this lane will not do.
        #expect(offer.labels.count == 2)
        #expect(Set(offer.labels) == ["Skip Ads", "Skip Intro"])
    }
}
