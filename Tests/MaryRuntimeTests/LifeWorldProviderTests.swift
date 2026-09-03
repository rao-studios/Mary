//
//  LifeWorldProviderTests.swift
//  MaryRuntimeTests
//
//  WHAT: Which disciplines the lead place offers the idle engine.
//  OUT:  LifeWorldProvider.disciplines
//  PIN:  THE LEAD PLACE DECIDES. The engine reaches for a ready adapter only
//        when the app in front declares that discipline — the old idle loop
//        fell back to any ready one, so a Writing adapter acted in Xcode.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryRuntime

private struct AllDisciplines: AbilityCapabilityIndex {
    var revision: UUID { UUID(uuidString: "22222222-2222-2222-2222-222222222222")! }
    func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    func paradigm(of _: AbilityID) -> AbilityParadigm? { .discipline }
}

private struct ExpertiseOnly: AbilityCapabilityIndex {
    var revision: UUID { UUID(uuidString: "33333333-3333-3333-3333-333333333333")! }
    func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    func paradigm(of _: AbilityID) -> AbilityParadigm? { .applicationExpertise }
}

@Suite struct LifeWorldProviderTests {

    private let textEdit = ApplicationProfile(
        id: "textedit", summary: "Notes.", abilities: [.writing, .coding])

    @Test func theLeadApplicationsDisciplinesAreOffered() {
        let found = LifeWorldProvider.disciplines(
            lead: .application("textedit"),
            profiles: [textEdit],
            abilities: AllDisciplines())
        #expect(found == [.coding, .writing])
    }

    @Test func anApplicationWithNoProfileOffersNothing() {
        let found = LifeWorldProvider.disciplines(
            lead: .application("sketch"),
            profiles: [textEdit],
            abilities: AllDisciplines())
        #expect(found.isEmpty)
    }

    /// Expertise never gets a LoRA, so it is never something to act through.
    @Test func expertiseIsNotOffered() {
        let found = LifeWorldProvider.disciplines(
            lead: .application("textedit"),
            profiles: [textEdit],
            abilities: ExpertiseOnly())
        #expect(found.isEmpty)
    }

    @Test func aLaneLeadOffersNothing() {
        let found = LifeWorldProvider.disciplines(
            lead: .lane(.applications),
            profiles: [textEdit],
            abilities: AllDisciplines())
        #expect(found.isEmpty)
    }

    /// Sorted, so the same world always picks the same discipline.
    @Test func theOrderIsStable() {
        let first = LifeWorldProvider.disciplines(
            lead: .application("textedit"), profiles: [textEdit],
            abilities: AllDisciplines())
        let second = LifeWorldProvider.disciplines(
            lead: .application("textedit"), profiles: [textEdit],
            abilities: AllDisciplines())
        #expect(first == second)
    }

    @Test func theIdleQueryIsAConstant() {
        // The place is carried by `ambient_lead`; a query that changes with
        // the app name is a second, noisier encoding of the same thing.
        #expect(LifeWorldProvider.idleQuery == "idle")
    }
}
