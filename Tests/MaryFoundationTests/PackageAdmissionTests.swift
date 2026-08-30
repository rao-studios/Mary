//
//  PackageAdmissionTests.swift
//  MaryFoundationTests
//
//  THE WHOLE GRAMMAR, EXERCISED END TO END ON A TEXTEDIT-SHAPED PACKAGE.
//
//  Everything in Mary's plugin story rests on one claim: an application can be
//  taught entirely by declaration. This file is where that claim is checked
//  rather than assumed — a package that names a bundle identifier, presses one
//  chord, and declares where the text lives must pass every validator, survive
//  the codec byte-for-byte, and carry a digest that notices tampering.
//
//  Two refusals matter as much as the acceptance, and both concern EYES:
//
//  A workspace perception claim says "point the document channel at me". The
//  only channel a package can be given is one of Mary's own observation
//  adapters, configured by a declaration. A claim with nothing behind it would
//  be a perception card asserting live knowledge of a document nobody is
//  reading — so the claim and the channel are one fact, checked together.
//
//  A recipe cannot return a value. The managed-UI engine presses keys and
//  reports whether the press landed; there is no channel for handing data
//  back. A package that realizes a Skill WITH outputs through a recipe is
//  claiming a read it structurally cannot perform, and the graph validator
//  says so by name.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct PackageAdmissionTests {

    // MARK: - Acceptance

    @Test func theMinimalDisciplineIsAdmitted() {
        let validation = AbilityPackageValidator.validate(PackageFixtures.minimalDiscipline)
        #expect(
            validation.issues.filter { $0.severity == .error }.isEmpty,
            "\(validation.issues)")
    }

    /// THE CENTRAL CLAIM. Identity, a chord operation, a realization, and a
    /// prose surface — an application taught with no Swift written about it.
    @Test func anApplicationTaughtOnlyByDeclarationIsAdmitted() {
        let package = PackageFixtures.applicationExpertise
        let packageValidation = AbilityPackageValidator.validate(package)
        #expect(
            packageValidation.issues.filter { $0.severity == .error }.isEmpty,
            "\(packageValidation.issues)")

        let plugin = package.plugin
        #expect(plugin != nil)
        if let plugin {
            let pluginValidation = PluginValidator.validate(plugin, in: package)
            #expect(
                pluginValidation.issues.filter { $0.severity == .error }.isEmpty,
                "\(pluginValidation.issues)")
        }

        let graph = PluginGraphValidator.validate([package])
        #expect(
            graph.issues.filter { $0.severity == .error }.isEmpty,
            "\(graph.issues)")
    }

    // MARK: - Eyes are two halves

    @Test func aWorkspaceClaimCarriesItsProseSurface() throws {
        let package = PackageFixtures.applicationExpertise
        let plugin = try #require(package.plugin)
        #expect(plugin.application.perception?.kind == .workspace)
        #expect(plugin.proseSurface != nil)
        #expect(!PluginValidator.validate(plugin, in: package).issues.contains {
            $0.code == "unsupported-workspace-perception"
        })
    }

    /// Strip the channel and the claim is refused by name.
    @Test func aWorkspaceClaimWithoutAProseSurfaceIsRefused() throws {
        var package = PackageFixtures.applicationExpertise
        var plugin = try #require(package.plugin)
        plugin.proseSurface = nil
        package.plugin = plugin

        let issue = try #require(
            PluginValidator.validate(plugin, in: package).issues.first {
                $0.code == "unsupported-workspace-perception"
            })
        #expect(issue.severity == .error)
        #expect(issue.path.hasSuffix("application.perception.kind"), "\(issue.path)")
    }

    /// A SELECTION-ONLY CLAIM NEEDS NOTHING. `perceptionOnly` asks for the
    /// generic Accessibility reader, which every application gets. Without
    /// this, the rule would quietly become "every perceiving package must
    /// declare a prose surface", which is false for anything that is not a
    /// text editor.
    @Test func aSelectionOnlyClaimNeedsNoProseSurface() throws {
        var package = PackageFixtures.applicationExpertise
        var plugin = try #require(package.plugin)
        plugin.application.perception = .init(kind: .perceptionOnly)
        plugin.proseSurface = nil
        package.plugin = plugin

        #expect(!PluginValidator.validate(plugin, in: package).issues.contains {
            $0.code == "unsupported-workspace-perception"
        })
    }

    /// THE SCHEMA CLOSES THE EXECUTABLE DOOR. Naming a Mary-owned observer is
    /// allowed; supplying one is not. A package that tries to carry its own
    /// document operation or polling cadence fails to decode at all.
    @Test(arguments: ["documentOperation", "pollSeconds"])
    func aPerceptionClaimCannotCarryAnOperationOrCadence(_ key: String) {
        let json = Data("""
        { "kind": "workspace", "\(key)": "anything" }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginApplicationPerceptionSchema.self, from: json)
        }
    }

    // MARK: - A recipe returns nothing

    @Test func aRealizedSkillWithOutputsIsRefused() throws {
        var package = PackageFixtures.applicationExpertise
        package.valueTypes.append(
            ValueTypeSchema(
                id: "tests.editor.text",
                title: "Editor text",
                summary: "Text read from the editor.",
                shape: .string))
        package.skills[0].outputs = [
            SkillPortSchema(
                name: "text",
                valueType: "tests.editor.text",
                summary: "What the document said.")
        ]

        let issue = try #require(
            PluginGraphValidator.validate([package]).issues.first {
                $0.code == "output-contract-unsupported"
            })
        #expect(issue.severity == .error)
    }

    // MARK: - One letter, one meaning

    /// Two packages minting handles under the same letter is not experienced
    /// as an error — it is experienced as Mary reaching into the wrong
    /// document when the user says "the second one". Only the graph validator
    /// sees two packages at once, so only it can catch this.
    @Test func twoPackagesCannotMintTheSameHandlePrefix() throws {
        let first = PackageFixtures.applicationExpertise
        var second = first
        second.package.id = "tests.editor.two"
        second.ability.id = "tests.editor.two"
        var plugin = try #require(second.plugin)
        plugin.id = "tests.editor.two"
        plugin.application.id = "tests.editor.two"
        plugin.application.bundleIdentifiers = ["com.example.othereditor"]
        second.plugin = plugin

        let issue = try #require(
            PluginGraphValidator.validate([first, second]).issues.first {
                $0.code == "duplicate-handle-prefix"
            })
        #expect(issue.severity == .error)
    }

    // MARK: - The codec

    @Test func aPackageRoundTripsAndCarriesItsDigest() throws {
        let encoded = try AbilityPackageCodec.encoded(PackageFixtures.applicationExpertise)
        let decoded = try AbilityPackageCodec.decode(encoded)
        #expect(decoded.plugin?.proseSurface == PackageFixtures.proseSurface)
        #expect(decoded.integrity?.digest.isEmpty == false)
        #expect(try AbilityPackageCodec.encoded(decoded) == encoded)
    }

    /// TAMPERING IS NOTICED. Change one byte of the declaration after the
    /// digest was taken and the package no longer verifies — which is the
    /// whole reason unknown keys are refused everywhere: an ignored byte would
    /// be an unverified one.
    @Test func anEditedPackageFailsItsDigest() throws {
        let encoded = try AbilityPackageCodec.encoded(PackageFixtures.applicationExpertise)
        var package = try AbilityPackageCodec.decode(encoded)
        package.plugin?.proseSurface?.budgets.ambientExcerptCharacters = 999
        let tampered = try AbilityPackageCodec.canonicalData(package)
        #expect(throws: (any Error).self) {
            try AbilityPackageCodec.decode(tampered)
        }
    }
}

// MARK: - The validators are not no-ops

@Suite struct ValidatorLivenessTests {

    /// A GATE THAT CANNOT FAIL IS NOT A GATE. Every acceptance test above is
    /// of the form "no errors", which a validator that returned early for any
    /// reason would also satisfy. This one breaks the fixture in an obvious
    /// way and insists somebody notices.
    @Test func aPackageWhoseAbilityNamesAMissingSkillIsRefused() {
        var package = PackageFixtures.minimalDiscipline
        package.ability.skills = ["tests.minimal.nonexistent"]
        let issues = AbilityPackageValidator.validate(package).issues
            .filter { $0.severity == .error }
        #expect(!issues.isEmpty, "the package validator admitted a dangling Skill reference")
    }

    /// Likewise for the Plugin grammar: a realization pointing at no operation
    /// must be refused, or every "the plugin validates" test above is vacuous.
    @Test func aRealizationNamingNoOperationIsRefused() throws {
        var package = PackageFixtures.applicationExpertise
        var plugin = try #require(package.plugin)
        plugin.realizations = [
            .init(skillID: "tests.editor.save", operation: "no_such_operation")
        ]
        package.plugin = plugin

        let pluginIssues = PluginValidator.validate(plugin, in: package).issues
            .filter { $0.severity == .error }
        let graphIssues = PluginGraphValidator.validate([package]).issues
            .filter { $0.severity == .error }
        #expect(
            !(pluginIssues.isEmpty && graphIssues.isEmpty),
            "a realization naming no declared operation was admitted")
    }

    /// A SECOND CODE EDITOR IS TAUGHT BY DECLARATION. The family adapters
    /// already exist; what changes is the package — bundle id, AX identity,
    /// markers, optional CLI — not a compiled provider named after the app.
    @Test func aSecondCodeEditorIsTaughtByDeclarationAlone() throws {
        var package = PackageFixtures.applicationExpertise
        var plugin = try #require(package.plugin)
        plugin.proseSurface = nil
        var surface = PackageFixtures.codeSurface
        surface.handlePrefix = "F"
        surface.workspaceIdentity = PluginWorkspaceIdentitySchema(
            rootSource: .documentFile,
            focusedFileTitleSeparator: " · ",
            focusedFileTitlePart: .first)
        plugin.codeSurface = surface
        plugin.corpus = PluginCorpusSchema(
            include: ["swift"],
            projectMarkers: ["Package.swift"],
            notation: "swift",
            workspaceIdentity: surface.workspaceIdentity,
            build: PluginProjectBuildSchema(
                checkCommand: ["swift", "build"],
                testCommand: ["swift", "test"],
                testFilterFlag: "--filter"))
        plugin.application.targetClasses = ["code-workspace", "document-window"]
        plugin.application.perception = .init(kind: .workspace)
        package.plugin = plugin

        let pluginIssues = PluginValidator.validate(plugin, in: package).issues
            .filter { $0.severity == .error }
        #expect(pluginIssues.isEmpty, "\(pluginIssues)")
        #expect(
            surface.workspaceIdentity.focusedFileName(inTitle: "Buffer.swift · Forge")
                == "Buffer.swift")
    }
}
