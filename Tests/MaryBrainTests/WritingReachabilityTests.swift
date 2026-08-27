//
//  WritingReachabilityTests.swift
//  MaryBrainTests
//
//  THE REPORTED INCIDENT, pinned end to end:
//
//    writing | type_at_cursor is unavailable: does not match its
//    Ability-level routing policy.
//
//  Every attempt to write into a Scrivener manuscript died on that sentence.
//  Three separate defects had to line up for it, and each gets its own test
//  here so a regression names which one came back:
//
//    1. The Scrivener ApplicationProfile lost `.writing` when the Ability moved
//       from a native plugin to a Dynamic package. `PluginCompiler`
//       builds a profile's abilities from the package's own ability id plus its
//       realization owners — all `scrivener` — and nothing read
//       `writing.mary`'s declared affinity for the app.
//    2. `AmbientEngine.classify` reads exactly that field to choose between
//       `.compose` and `.operate`, so every action turn in a manuscript
//       classified as `.operate`.
//    3. `writing.mary`'s Ability-level routing admitted only
//       `compose`/`revise`/a live selection, and that predicate was enforced at
//       DISPATCH — so a correct, already-chosen `type_at_cursor` was refused.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct WritingReachabilityTests {

    // MARK: - 1. The profile carries the discipline that claims the app

    /// AN APPLICATION JOINS A DISCIPLINE BY REALIZING ONE OF ITS SKILLS —
    /// which is proof rather than a list.
    ///
    /// A discipline package CAN name applications outright
    /// (`ability.applications`), and Mary's own do not. The list is the wrong
    /// channel: it makes the discipline's author decide which applications
    /// count, so the three they thought of are writing applications and every
    /// editor installed afterwards is not — no matter what its own package
    /// says about itself. Realization inverts that. The application declares
    /// what it can do, the discipline finds out, and nobody has to be
    /// enumerated in advance.
    @Test func anApplicationJoinsTheDisciplineItRealizesASkillFor() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("textedit"), try loadRootPackage("writing")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "textedit" })
        #expect(editor.abilities.contains(AbilityID("textedit")), "its own ability")
        #expect(
            editor.abilities.contains(.writing),
            "it realizes writing.save-document, so it is a writing application")
    }

    /// AND ONLY THAT DISCIPLINE. Merely being installed alongside one does
    /// not join it — otherwise every profile would carry every discipline and
    /// the register test would mean nothing.
    @Test func anUnrealizedDisciplineDoesNotJoinTheProfile() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [
                try loadRootPackage("textedit"),
                try loadRootPackage("writing"),
                try loadRootPackage("window-management"),
            ],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "textedit" })
        #expect(editor.abilities.contains(.writing), "it realizes a writing skill")
        #expect(
            !editor.abilities.contains(AbilityID("window-management")),
            "it realizes none of window-management's, so it does not join it")
    }

    // MARK: - 2. A manuscript turn is a writing turn

    /// With the profile fixed, an action turn led by Scrivener reads as
    /// `compose` — the register the whole Writing vocabulary hangs off.
    @Test func anActionTurnLedByAManuscriptIsAWritingTurn() {
        let scrivener = ApplicationProfile(
            id: "scrivener",
            title: "Scrivener",
            summary: "Manuscript.",
            abilities: [AbilityID("scrivener"), .writing],
            aliases: ["scrivener", "manuscript"])
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: "write a paragraph about the Queen of Vanta",
            actionTurn: true,
            leadApplicationID: "scrivener",
            profiles: [scrivener]))

        #expect(route.intent == AmbientIntent.compose)
        #expect(route.decidedBy == AmbientSignal.writingRegister)
    }

    /// And the same turn WITHOUT the discipline on the profile is the bug:
    /// kept as the negative half so the mechanism is visible rather than
    /// implied.
    @Test func theSameTurnWithoutTheDisciplineFallsToOperate() {
        let scrivener = ApplicationProfile(
            id: "scrivener",
            title: "Scrivener",
            summary: "Manuscript.",
            abilities: [AbilityID("scrivener")],
            aliases: ["scrivener", "manuscript"])
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: "write a paragraph about the Queen of Vanta",
            actionTurn: true,
            leadApplicationID: "scrivener",
            profiles: [scrivener]))

        #expect(route.intent == AmbientIntent.operate)
    }

    // MARK: - 3. Being in a writing world is enough to reach Writing

    /// THE OFFER GATE TURNS ON A PHYSICAL FACT NOW.
    ///
    /// The three original predicates are all classifier output, so a turn the
    /// classifier read as anything else — a bare "yes please do" answering a
    /// proposal, which resolves to `.decide` — dropped the entire Writing
    /// Ability out of the roster and took `type_at_cursor` with it. Sitting in
    /// a manuscript is not a reading of the sentence; it is where the user is.
    /// THIS TEST HAND-BUILT A VALUE NO TAUGHT TURN COULD PRODUCE, and for a
    /// while that made it a promise rather than a proof: `workspaceFamily` was
    /// `route.lead?.ability`, and `AmbientWorld.ability` answers only for the
    /// compiled worlds — so the guarantee "being in a writing workspace is
    /// enough" held in Pages and nowhere else. It is real now because the
    /// value comes off `route.leadPlace`, and
    /// `TaughtApplicationParityTests.aTaughtWorkspaceLeadEarnsTheWorkspaceSignals`
    /// pins that a taught manuscript application actually produces it.
    @Test func theWritingAbilityIsReachableFromAWritingWorkspaceAlone() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inAManuscriptAnsweringYes = AbilityRoutingContext(
            utterance: "yes please do",
            intent: AmbientIntent.decide.rawValue,
            workspaceFamily: AbilityID.writing.rawValue)

        #expect(
            AbilityRoutingEvaluator.isEligible(writing.routing, in: inAManuscriptAnsweringYes),
            "the typer must survive a turn the classifier did not read as compose")
    }

    /// The predicate is not a blank cheque: a coding workspace with none of the
    /// writing signals still does not admit the Writing Ability.
    @Test func aCodingWorkspaceStillDoesNotAdmitWriting() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inXcode = AbilityRoutingContext(
            utterance: "run the tests",
            intent: AmbientIntent.operate.rawValue,
            workspaceFamily: "coding")

        #expect(!AbilityRoutingEvaluator.isEligible(writing.routing, in: inXcode))
    }

    /// THE SHIPPED PACKAGES, not fixtures. What broke here was the real
    /// `writing.mary` meeting the real `scrivener.mary`, and a fixture pair
    /// would have agreed with itself while the installed pair did not.
    /// Loads one shipped package by name, skipping the whole test while
    /// `Abilities/` is still empty — see `InstalledPackagesGate`. The
    /// reachability property is about the SHIPPED set, so a fixture package
    /// would answer a different question than the one asked.
    private func loadRootPackage(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let candidate = abilities.appendingPathComponent("\(name).mary")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(from: candidate)
    }
}
