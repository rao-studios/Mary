import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryFoundation

@Suite struct PairProgramPackageTests {

    @Test func pairProgramIsAStateMachineWithTheCodingLoop() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let url = abilities.appendingPathComponent("coding.mary")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let package = try AbilityPackageCodec.load(from: url)
        let pair = try #require(package.skills.first { $0.id == "coding.pair-program" })
        #expect(pair.kind == .workflow)
        #expect(pair.execution.kind == .stateMachine)
        #expect(pair.invocationName == "pair_program")
        #expect(pair.modelExposure.parameters.contains { $0.name == "task" })
        #expect(!pair.requirements.supportingAbilities.contains("architect"))
        let operations = pair.execution.steps.map(\.operation)
        #expect(operations == [
            "current_file",
            "read_symbol",
            "project_outline",
            "plan_minimal_code_change",
            "complete_coding_change",
            "build_check",
            "explain_code_change",
        ])
        let implement = try #require(pair.execution.steps.first { $0.id == "implement" })
        #expect(implement.consumes.contains("plan"))
        #expect(implement.consumes.contains("request"))
    }

    @Test func planAndExplainAreWorkflowOnlyCognitiveSkills() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let url = abilities.appendingPathComponent("coding.mary")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let package = try AbilityPackageCodec.load(from: url)
        let plan = try #require(
            package.skills.first { $0.id == "coding.plan-minimal-code-change" })
        let explain = try #require(
            package.skills.first { $0.id == "coding.explain-code-change" })
        #expect(plan.kind == .cognitive)
        #expect(explain.kind == .cognitive)
        #expect(!plan.modelExposure.enabled)
        #expect(!explain.modelExposure.enabled)
        #expect(plan.invocationName == nil)
        #expect(explain.invocationName == nil)
        #expect(package.valueTypes.contains { $0.id == "coding.change-request" })
    }

    @Test func completeCodingChangeTakesATask() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let url = abilities.appendingPathComponent("coding.mary")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let package = try AbilityPackageCodec.load(from: url)
        let complete = try #require(
            package.skills.first { $0.id == "coding.complete-change" })
        #expect(complete.invocationName == "complete_coding_change")
        #expect(complete.modelExposure.parameters.contains { $0.name == "task" })
    }

    @Test func codingAgentFacultyStaysOnTheHandshakeRoster() {
        let adapters = MaryAdapterCatalog.adapters()
            + [
                AffordancePlugin(),
                LookingPlugin { _ in SkillOutcome(ok: true, summary: "") },
                CodingAgentAdapter(),
            ]
        #expect(adapters.contains { $0.name == "coding-agent" })
        #expect(!MaryAdapterCatalog.adapters().contains { $0.name == "coding-agent" })
        let fragment = CodingAgentAdapter().promptFragment ?? ""
        #expect(fragment.contains("delegate_coding"))
        #expect(!fragment.lowercased().contains("xcode"))
    }

    @Test func defaultCodingModelIdIsTheHubSnapshot() {
        #expect(MaryCodingEngine.defaultModelID
            == "mlx-community/gemma-4-12b-coder-fable5-composer2.5-4bit")
    }
}
