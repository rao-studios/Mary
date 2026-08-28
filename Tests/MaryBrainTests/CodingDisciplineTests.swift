//
//  CodingDisciplineTests.swift
//  MaryBrainTests
//
//  THE CODING DISCIPLINE, AS SHIPPED — the road `coding.mary` and
//  `xcode.mary` have to travel before Mary can be asked to build anything.
//
//  WHAT MAKES THIS WORTH ITS OWN SUITE. `WritingReachabilityTests` pins the
//  same road for writing, and it exists because three separate defects had to
//  line up before a manuscript could be typed into. Coding is the second
//  discipline to travel that road and the first to do so with no compiled
//  provider anywhere behind it: writing has the prose-surface adapter, coding
//  has nothing but declarations. Every rung here is therefore load-bearing in
//  a way the writing equivalents are not, because nothing else would catch a
//  break.
//
//  AND ONE RUNG IS NEWLY REPAIRED. `AmbientPlace.ability` used to break ties
//  with `AmbientWorld.realizedAbilities`, which the world shrink left
//  permanently empty — so a taught application's craft came back as whichever
//  of its ability ids sorted first alphabetically. For an editor that is its
//  OWN id ("xcode" before "coding"), which would leave `focus` nil and the
//  `workspaceFamily == "coding"` predicate unreachable. The order now comes
//  from `WorkspaceFocus`. These tests are what stop that from rotting back.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct CodingDisciplineTests {

    // MARK: - The discipline is joined by realizing, not by being listed

    /// THE EDITOR JOINS CODING BECAUSE IT REALIZES CODING'S SKILLS.
    ///
    /// `coding.mary` names no applications — deliberately, the same call
    /// `writing.mary` makes. If this fails, either the realization block lost
    /// its `skillID`s or the compiler stopped reading realization owners, and
    /// every rung below it is meaningless.
    @Test func theEditorJoinsCodingByRealizingItsSkills() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("xcode"), try loadRootPackage("coding")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        #expect(editor.abilities.contains(AbilityID("xcode")), "its own ability")
        #expect(
            editor.abilities.contains(.coding),
            "it realizes coding's build/run/test skills, so it is a coding application")
    }

    /// AND NOT WRITING. A code editor must never read as a prose workspace:
    /// that is the distinction the whole rival-writing bar rests on, and the
    /// one `SelectionSurfacePolicy` enforces from the other direction.
    @Test func theEditorIsNotAWritingApplication() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [
                try loadRootPackage("xcode"),
                try loadRootPackage("coding"),
                try loadRootPackage("writing"),
            ],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        #expect(editor.abilities.contains(.coding))
        #expect(
            !editor.abilities.contains(.writing),
            "it realizes none of writing's skills, so it does not join writing")
    }

    // MARK: - The compiled profile projects onto the discipline axis

    /// THE JOIN THE TIE-BREAK REPAIR EXISTS FOR.
    ///
    /// `abilities` is a `Set` holding BOTH "xcode" and "coding", and the place
    /// has to project that onto `WorkspaceFocus`. Under the old alphabetical
    /// fallback "xcode" lost to nothing and won the tie, `focus` came back
    /// nil, and a code workspace silently had no discipline at all.
    @Test func theEditorsPlaceReadsAsCoding() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("xcode"), try loadRootPackage("coding")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })

        try AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode",
                    profile: profile,
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    worldClass: .workspace,
                    displayName: "Xcode",
                    perception: ApplicationPerception(kind: .workspace, documentOperation: nil, pollSeconds: 3)),
            ])
        ) {
            let place = AmbientPlace.application("xcode")
            #expect(place.focus == .coding, "the discipline it realized")
            // NO EYES, AND THAT IS THE HONEST ANSWER TODAY. `hasEyes` requires
            // a channel that reads the application's documents, and this cut
            // ships none for code: every value-returning code Skill — read a
            // file, read a symbol, outline the project — needs a compiled
            // provider Mary does not have. So Mary can DRIVE the editor and
            // cannot SEE into it, and this line is where that stops being an
            // oversight and becomes a recorded state. It flips when the
            // code-surface adapter lands, and this test is where that shows.
            #expect(!place.hasEyes, "no code-surface reader ships yet")
            // THE SAME VALUE THE ROSTER GATE READS. `workspaceFamily` is
            // `leadPlace.ability?.rawValue`, and `coding.mary` admits itself
            // through a `workspaceFamily == "coding"` predicate — the one
            // admission road that does not depend on classifying a sentence.
            #expect(place.ability == .coding)
        }
    }

    // MARK: - What the packages promise

    /// EVERY CODING SKILL IS REALIZED BY THE EDITOR. A discipline skill with
    /// no realization anywhere is installed-but-blocked, which the validator
    /// reports as a note and a user experiences as Mary agreeing to do
    /// something and then not doing it.
    @Test func everyCodingSkillHasARealization() throws {
        guard InstalledPackages.installed() != nil else { return }
        let coding = try loadRootPackage("coding")
        let editor = try loadRootPackage("xcode")

        let declared = Set(coding.skills.map(\.id.rawValue))
        let realized = Set(
            (editor.plugin?.realizations ?? []).map(\.skillID.rawValue))
        #expect(declared == realized, """
            Every Skill the coding discipline declares must be realized by the \
            editor package, and the editor must realize nothing the discipline \
            does not declare.
            declared only: \(declared.subtracting(realized).sorted())
            realized only: \(realized.subtracting(declared).sorted())
            """)
    }

    /// EVERY OPERATION IS A CHORD THE HANDS CAN POST.
    ///
    /// `MaryHands` posts key chords, text, waits and window rebinds; the
    /// compiler refuses a pointer step before the stage is ever taken. A
    /// shipped package containing one would validate, install, and fail at
    /// first use — so the check belongs on the packages, not on the executor.
    @Test func everyEditorOperationIsPerformable() throws {
        guard InstalledPackages.installed() != nil else { return }
        let editor = try loadRootPackage("xcode")
        let performable: Set<PluginRecipeStepKind> =
            [.keyChord, .typeText, .wait, .rebindFocusedWindow]

        for operation in editor.plugin?.operations ?? [] {
            for step in operation.steps {
                #expect(
                    performable.contains(step.kind),
                    "\(operation.operation) step \(step.id) is \(step.kind), which Mary's hands cannot post")
            }
        }
    }

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
