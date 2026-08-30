//
//  GuardrailCategoryProjectionSecurityTests.swift
//  MaryBrainTests
//
//  WHAT: Closed guardrail cases expand to Mary-owned sentences, never package prose.
//  OUT:  Prompt projection of GuardrailCategory
//  PIN:  Companion to GuardrailCategoryAdmissionTests
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct GuardrailCategoryProjectionSecurityTests {

    /// EVERY CASE, ONE FIXED SENTENCE, NOTHING ELSE. `guardrailSentence` has
    /// no default branch — a new `GuardrailCategory` case fails to compile
    /// there until it is given real wording — so the exhaustive switch
    /// itself is the closure guarantee; this test pins the fixed vocabulary
    /// so a future edit cannot quietly widen what the branch is allowed to
    /// say.
    @Test func abilityLevelCautionSentencesAreDrawnFromAFixedVocabulary() {
        let allowlist: Set<String> = [
            "Domain caution: do not apply this outside the surface kind it was built for (for example, prose vs. code).",
            "Scope caution: act only on the target the user explicitly named or focused, never an inferred neighbor.",
            "Freshness caution: read live state before acting or reporting; never answer from a remembered value.",
            "Focus caution: never bring the target forward or steal focus merely to observe or command it.",
            "Command caution: issue this through the target application's own command, never synthesized input standing in for it.",
            "Irreversible caution: this can destroy or replace existing content; confirm the exact, fresh target before acting.",
        ]
        for category in GuardrailCategory.allCases {
            let sentence = AbilityPromptProjection.guardrailSentence(for: category)
            #expect(allowlist.contains(sentence), "unlisted sentence for \(category): \(sentence)")
        }
    }

    /// THE OPERATION-LEVEL SIBLING. A separate switch, a separate fixed
    /// vocabulary — deliberately not shared text with the ability-level one,
    /// since `AbilityRuntime.projectedBindingDescription` is a different
    /// seam with its own wording, but the same closure property: exhaustive,
    /// no default, nothing but these six sentences can ever come out.
    @Test func operationLevelCautionSentencesAreDrawnFromAFixedVocabulary() {
        let allowlist: Set<String> = [
            "Domain caution: do not use this outside the surface kind it was built for (for example, prose vs. code).",
            "Scope caution: applies only to the target the user explicitly named or focused, never an inferred neighbor.",
            "Freshness caution: read live state before acting or reporting; never answer from a remembered value.",
            "Focus caution: never bring the target forward or steal focus merely to observe or command it.",
            "Command caution: this issues the target application's own command; never substitute synthesized input for it.",
            "Irreversible caution: this can destroy or replace existing content; confirm the exact, fresh target before acting.",
        ]
        for category in GuardrailCategory.allCases {
            let sentence = AbilityRuntime.cautionSentence(for: category)
            #expect(allowlist.contains(sentence), "unlisted sentence for \(category): \(sentence)")
        }
    }

    /// THE REAL MIGRATED PACKAGE, RENDERED FOR REAL. `xcode.mary` now
    /// declares `guardrailCategories` (this session's Part A migration); this
    /// drives the actual shipped bytes through `AbilityPromptProjection.render`
    /// and checks the fixed sentence appears — and that the free-text
    /// `guardrails` sitting right next to it in the same JSON object never
    /// does, the same boundary `AbilityPromptProjectionSecurityTests`
    /// already guards for every other ability-level field.
    @Test func theMigratedXcodeAbilityRendersFixedCautionSentencesFromRealShippedData() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("xcode")
        let categories = package.ability.operatingPolicy.guardrailCategories
        #expect(
            !categories.isEmpty,
            "this test exists to prove the live migration; the shipped package must still declare it")

        let record = AbilityPackageRecord(
            package: package, source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/Abilities/xcode.mary"),
            validation: AbilityPackageValidator.validate(package),
            rawData: Data())
        let snapshot = AbilityRuntimeSnapshot(
            records: [record], validation: record.validation, adapterManifests: [])
        let route = AmbientRoute(
            intent: .converse, decidedBy: .none,
            gate: AmbientIntentGate(requestedAbilities: [package.ability.id]))

        let rendered = AbilityPromptProjection.render(snapshot: snapshot, route: route)
        #expect(!rendered.isEmpty)

        for category in categories {
            let expected = "CAUTION: \(AbilityPromptProjection.guardrailSentence(for: category))"
            #expect(rendered.contains(expected), "missing fixed sentence for \(category)")
        }
        for freeTextGuardrail in package.ability.operatingPolicy.guardrails {
            #expect(!rendered.contains(freeTextGuardrail), "raw guardrail prose escaped: \(freeTextGuardrail)")
        }
    }

    /// THE OPERATION-LEVEL SIBLING, DRIVEN END TO END. `xcode.mary`'s build
    /// operation now carries `caution: nativeCommandOnly` (this session's
    /// Part B migration), realized through `coding.build-project`. This
    /// drives the real compiled plugin graph and the real dispatcher —
    /// `AbilityRuntime.schemas`, the exact surface the model sees — and
    /// checks the projected `build_project` description carries the fixed
    /// sentence, never anything else.
    @Test func theMigratedXcodeBuildOperationRendersItsFixedCautionSentenceThroughRealDispatch() async throws {
        guard InstalledPackages.installed() != nil else { return }
        let xcode = try loadRootPackage("xcode")
        let coding = try loadRootPackage("coding")
        let windowManagement = try loadRootPackage("window-management")
        let allPackages = [xcode, coding, windowManagement]

        let buildOperation = try #require(
            xcode.plugin?.operations.first { $0.operation == "xcode_build_project" })
        #expect(
            buildOperation.caution == .nativeCommandOnly,
            "this test exists to prove the live migration; the shipped operation must still declare it")

        let compilation = PluginCompiler.compile(
            packages: allPackages,
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let xcodeProfile = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        let perception = try #require(xcodeProfile.perception)

        let validation = AbilityPackageValidator.validateGraph(allPackages)
        #expect(validation.isValid, "the shipped packages must load cleanly together")
        func record(_ package: MaryAbilityPackage) -> AbilityPackageRecord {
            AbilityPackageRecord(
                package: package, source: .installed,
                sourceURL: URL(fileURLWithPath: "/dev/null"),
                validation: validation,
                rawData: (try? AbilityPackageCodec.encoded(package)) ?? Data())
        }
        let snapshot = AbilityRuntimeSnapshot(
            records: allPackages.map(record),
            validation: validation,
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            plugins: compilation)

        let ambient = AmbientContextStore()

        try await AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode", profile: xcodeProfile,
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    worldClass: .workspace, displayName: "Xcode",
                    perception: perception),
            ])
        ) {
            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "build the project",
                leadApplicationID: "xcode",
                profiles: [xcodeProfile]))
            #expect(route.leadPlace?.ability?.rawValue == "coding",
                    "the turn must actually read as a coding workspace for this to be a real test")
            ambient.noteUtterance("build the project")
            ambient.noteRoute(route)

            try await AbilityTurnContext.$snapshot.withValue(snapshot) {
                let runtime = AbilityRuntime(
                    plugins: MaryAdapterCatalog.adapters(),
                    ambient: ambient,
                    contextProvider: { AbilityExecutionContext(projects: [:]) })
                let build = try #require(runtime.schemas.first { $0.name == "build_project" })
                let expected = AbilityRuntime.cautionSentence(for: .nativeCommandOnly)
                #expect(build.description.contains(expected),
                        "real dispatch description: \(build.description)")
                #expect(!build.description.contains("GUARDRAIL_PAYLOAD"))
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
