//
//  AmbientRealmResolverTests.swift
//  MaryAmbientTests
//
//  WHAT: Who could serve and why — resolver output as a recoverable record.
//  OUT:  AmbientRealmResolver
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

    /// THE FIELD NOTHING HAS EVER READ. `targetClasses` has been populated by
    /// packages and consumed by no code at all — so an author could describe
    /// exactly what their application accepts and never be matched on a word
    /// of it. It reaches a candidate now, which is what puts it in the record.

    /// CONFORMED BUT COLD is the distinction the whole record exists for: the
    /// same set, with and without evidence, is what explains a choice.

    /// THE ORDER IS STABLE ACROSS RUNS. A record whose order depends on a hash
    /// seed cannot be diffed against itself.

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

    /// THE LEAD DID NOT CONFORM, so the turn is about something warm beside
    /// it — `coActive` arrives already ranked, strongest evidence first.

    // MARK: - The pinned invariant

    /// `realm.place == focus.lead` WHENEVER BOTH EXIST AND THE LEAD CONFORMS.
    ///
    /// The resolver READS the focus signal rather than re-deciding with it,
    /// and this is the test that keeps it honest: a second place-picker
    /// disagreeing with the first is the exact class of bug the whole
    /// World/Realm/Place reorganisation was done to remove.

    // MARK: - The set survives the decision

    /// THE WHOLE REASON THIS IS A SET AND NOT A PLACE. An episode saying "she
    /// wrote in Quill" teaches an association; one saying "two applications
    /// conformed, Quill led by activation, Studio was cold" teaches the
    /// judgement.
}
