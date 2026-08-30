//
//  AmbientRealmResolverTests.swift
//  MaryAmbientTests
//
//  WHO COULD SERVE, AND WHY THAT ONE.
//
//  The resolver's output is a dataset row before it is anything else, so what
//  these tests hold is mostly the RECORD: that a candidate carries what it
//  conformed by, that the set survives the decision, that the reasoning is
//  recoverable from the row alone. A resolver that picked correctly and
//  recorded nothing would pass a place test and fail at its actual job.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryAmbient

@Suite struct AmbientRealmResolverTests {

    // MARK: - The world these tests live in

    /// Three taught applications. The names are invented; see
    /// `PassageRosterFixture` on why a fixture that names a real product
    /// invites a reader to believe Mary knows about it.
    private func registration(
        _ id: String,
        abilities: Set<AbilityID>,
        targetClasses: Set<String> = [],
        eyes: Bool = true
    ) -> ApplicationRegistration {
        ApplicationRegistration(
            id: id,
            profile: ApplicationProfile(
                id: id, title: id.capitalized, summary: "A fixture.",
                abilities: abilities,
                targetClasses: targetClasses),
            bundleIdentifiers: ["com.example.\(id)"],
            worldClass: .workspace,
            displayName: id.capitalized,
            perception: eyes
                ? ApplicationPerception(
                    kind: .workspace, documentOperation: "read", pollSeconds: 3)
                : nil)
    }

    /// An index that answers a fixed need for any utterance.
    private struct FixedAbilities: AbilityCapabilityIndex {
        let revision = UUID()
        let answer: Set<AbilityID>
        func requestedAbilities(in _: String) -> Set<AbilityID> { answer }
    }

    private var quill: ApplicationRegistration {
        registration("quill", abilities: [.writing], targetClasses: ["editable-prose-surface"])
    }
    private var forge: ApplicationRegistration {
        registration("forge", abilities: [.coding], targetClasses: ["code-workspace"])
    }
    /// Conforms to BOTH — the case the user's own framing turns on.
    private var studio: ApplicationRegistration {
        registration("studio", abilities: [.writing, .coding])
    }

    private func inputs(
        _ utterance: String,
        registrations: [ApplicationRegistration],
        need: Set<AbilityID> = [],
        discipline: WorkspaceFocus? = nil,
        named: Set<AmbientPlace> = [],
        lead: AmbientPlace? = nil,
        coActive: [AmbientPlace] = [],
        evidence: [AmbientPlace: FocusEvidence] = [:],
        decidedBy: AmbientSignal? = .attention
    ) -> AmbientRealmResolver.Inputs {
        AmbientRealmResolver.Inputs(
            utterance: utterance,
            namedPlaces: named,
            discipline: discipline,
            decidedBy: decidedBy,
            focus: FocusSignal(lead: lead, coActive: coActive),
            evidence: evidence,
            registrations: registrations,
            abilities: FixedAbilities(answer: need))
    }

    // MARK: - The need

    @Test func anEmptyNeedIsARealAnswerRatherThanAFailedClassification() {
        let realm = AmbientRealmResolver.resolve(
            inputs("what's that?", registrations: [quill, forge]))
        #expect(realm.need.isEmpty)
        // Nothing was asked for, so nothing can fail to conform — the
        // alternative would claim no application could have served the turn.
        #expect(realm.candidates.count == 2)
    }

    @Test func anEmptyNeedSettlesOnTheCurrentlyActiveLead() {
        let realm = AmbientRealmResolver.resolve(
            inputs("what's that?", registrations: [quill, forge],
                   lead: .application("forge")))
        #expect(realm.need.isEmpty)
        #expect(realm.place == .application("forge"))
    }

    @Test func theNeedCarriesBothAxesWhenBothArePresent() {
        let realm = AmbientRealmResolver.resolve(
            inputs("tidy the draft", registrations: [quill],
                   need: [.writing], discipline: .writing))
        #expect(realm.need.abilities == [.writing])
        #expect(realm.need.discipline == .writing)
    }

    // MARK: - The realm

    /// AN APPLICATION ANSWERING TWO NEEDS APPEARS ONCE, carrying both. This is
    /// the user's own framing — "a realm that can conform to both is seen" —
    /// and splitting it would let one place compete with itself for the lead.
    @Test func onePlaceConformingTwiceIsOneCandidateWithBothConformances() {
        let realm = AmbientRealmResolver.resolve(
            inputs("write the doc comment", registrations: [studio],
                   need: [.writing, .coding], discipline: .writing))

        #expect(realm.candidates.count == 1)
        let only = realm.candidates[0]
        #expect(only.conformsByAbilities == [.writing, .coding])
        #expect(only.place == .application("studio"))
    }

    @Test func aPlaceThatConformsToNeitherAxisIsNotACandidate() {
        let realm = AmbientRealmResolver.resolve(
            inputs("fix the build", registrations: [quill, forge], need: [.coding]))
        #expect(realm.candidates.map(\.place) == [.application("forge")])
    }

    /// THE FIELD NOTHING HAS EVER READ. `targetClasses` has been populated by
    /// packages and consumed by no code at all — so an author could describe
    /// exactly what their application accepts and never be matched on a word
    /// of it. It reaches a candidate now, which is what puts it in the record.
    @Test func aCandidateCarriesTheTargetClassesItsPackageDeclared() {
        let realm = AmbientRealmResolver.resolve(
            inputs("revise it", registrations: [quill], need: [.writing]))
        #expect(realm.candidates.first?.targetClasses == ["editable-prose-surface"])
    }

    /// CONFORMED BUT COLD is the distinction the whole record exists for: the
    /// same set, with and without evidence, is what explains a choice.
    @Test func aCandidateCarriesTheKindAndAgeOfItsEvidence() {
        let now = Date()
        let place = AmbientPlace.application("quill")
        let realm = AmbientRealmResolver.resolve(
            AmbientRealmResolver.Inputs(
                utterance: "revise it",
                discipline: .writing,
                focus: FocusSignal(lead: place),
                evidence: [place: FocusEvidence(
                    place: place, kind: .activation, at: now.addingTimeInterval(-4))],
                registrations: [quill],
                abilities: FixedAbilities(answer: [.writing]),
                now: now))

        let candidate = try? #require(realm.candidates.first)
        #expect(candidate?.evidence == .activation)
        #expect((candidate?.evidenceAgeSeconds ?? 0) >= 3.9)
        #expect((candidate?.evidenceAgeSeconds ?? 0) <= 4.1)
    }

    @Test func aConformingPlaceWithNoEvidenceIsStillRecordedAsACandidate() {
        let realm = AmbientRealmResolver.resolve(
            inputs("revise it", registrations: [quill], need: [.writing]))
        #expect(realm.candidates.count == 1)
        #expect(realm.candidates.first?.evidence == nil)
        // …and does not win, because standing is what separates "could act
        // there" from "should".
        #expect(realm.place == nil)
    }

    /// THE ORDER IS STABLE ACROSS RUNS. A record whose order depends on a hash
    /// seed cannot be diffed against itself.
    @Test func candidatesAreOrderedByPlaceTokenNotByHashSeed() {
        for _ in 0..<8 {
            let realm = AmbientRealmResolver.resolve(
                inputs("do it", registrations: [studio, forge, quill]))
            #expect(realm.candidates.map(\.place.token)
                    == ["applications:forge", "applications:quill", "applications:studio"])
        }
    }

    // MARK: - The place

    @Test func theFocusLeadWinsWhenItConforms() {
        let realm = AmbientRealmResolver.resolve(
            inputs("revise it", registrations: [quill, studio],
                   need: [.writing], lead: .application("studio")))
        #expect(realm.place == .application("studio"))
        #expect(realm.decidedBy == .attention)
    }

    /// A NAME IS AN ADDRESS, NOT A SIGNAL. It outranks a place the user is
    /// demonstrably looking at, because "do it in the other one" must work.
    @Test func aNamedPlaceOutranksTheFocusLead() {
        let realm = AmbientRealmResolver.resolve(
            inputs("revise it in quill", registrations: [quill, studio],
                   need: [.writing],
                   named: [.application("quill")],
                   lead: .application("studio")))
        #expect(realm.place == .application("quill"))
    }

    /// AND WINS EVEN WHEN IT DOES NOT CONFORM. Answering in a different
    /// application because the named one lacked a declared ability is the
    /// most confusing thing Mary can do. The realm records the
    /// non-conformance, which is the useful part.
    @Test func aNamedPlaceThatDoesNotConformStillTakesTheTurn() {
        let realm = AmbientRealmResolver.resolve(
            inputs("fix the build in quill", registrations: [quill, forge],
                   need: [.coding],
                   named: [.application("quill")],
                   lead: .application("forge")))
        #expect(realm.place == .application("quill"))
        // …and the record shows it was not among the conforming set.
        #expect(!realm.conforming.map(\.place).contains(.application("quill")))
    }

    /// THE LEAD DID NOT CONFORM, so the turn is about something warm beside
    /// it — `coActive` arrives already ranked, strongest evidence first.
    @Test func aCoActivePlaceTakesTheTurnWhenTheLeadDoesNotConform() {
        let realm = AmbientRealmResolver.resolve(
            inputs("revise the draft", registrations: [quill, forge],
                   need: [.writing],
                   lead: .application("forge"),
                   coActive: [.application("quill")]))
        #expect(realm.place == .application("quill"))
    }

    @Test func nothingConformingAndNothingNamedDecidesNoPlace() {
        let realm = AmbientRealmResolver.resolve(
            inputs("fix the build", registrations: [quill], need: [.coding]))
        #expect(realm.place == nil)
        #expect(realm.decidedBy == nil, "a realm with no place claims no decider")
        #expect(realm.isEmpty)
    }

    // MARK: - The pinned invariant

    /// `realm.place == focus.lead` WHENEVER BOTH EXIST AND THE LEAD CONFORMS.
    ///
    /// The resolver READS the focus signal rather than re-deciding with it,
    /// and this is the test that keeps it honest: a second place-picker
    /// disagreeing with the first is the exact class of bug the whole
    /// World/Realm/Place reorganisation was done to remove.
    @Test func theRealmsPlaceIsTheLeadWheneverTheLeadConforms() {
        for lead in ["quill", "studio"] {
            let realm = AmbientRealmResolver.resolve(
                inputs("revise it", registrations: [quill, studio, forge],
                       need: [.writing], lead: .application(lead)))
            #expect(realm.place == .application(lead))
        }
    }

    // MARK: - The set survives the decision

    /// THE WHOLE REASON THIS IS A SET AND NOT A PLACE. An episode saying "she
    /// wrote in Quill" teaches an association; one saying "two applications
    /// conformed, Quill led by activation, Studio was cold" teaches the
    /// judgement.
    @Test func theLosersStayInTheRecord() {
        let now = Date()
        let winner = AmbientPlace.application("quill")
        let realm = AmbientRealmResolver.resolve(
            AmbientRealmResolver.Inputs(
                utterance: "revise it",
                focus: FocusSignal(lead: winner),
                evidence: [winner: FocusEvidence(place: winner, kind: .activation, at: now)],
                registrations: [quill, studio],
                abilities: FixedAbilities(answer: [.writing]),
                now: now))

        #expect(realm.place == winner)
        #expect(realm.candidates.count == 2)
        let loser = realm.candidates.first { $0.place == .application("studio") }
        #expect(loser?.conformsByAbilities == [.writing], "the loser conformed")
        #expect(loser?.evidence == nil, "and had no standing — which is WHY it lost")
    }
}
