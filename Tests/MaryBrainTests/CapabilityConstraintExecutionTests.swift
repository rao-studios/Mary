import Foundation
import Testing
@testable import MaryBrain
@testable import MaryAdapters
@testable import MaryAmbient

@Suite struct CapabilityConstraintExecutionTests {
    @Test func directBindingRejectsOversizedInputBeforeAdapterRuns() async {
        let fixture = directFixture(constraints: [
            .init(kind: .maximumPayloadBytes, value: "128"),
        ])
        let probe = InvocationProbe()
        let runtime = runtime(bindings: [immediateBinding(
            fixture.operation,
            probe: probe)])

        let outcome = await AbilityTurnContext.$snapshot.withValue(fixture.snapshot) {
            await runtime.dispatch(
                name: fixture.invocation,
                argumentsJSON: json("payload", String(repeating: "x", count: 1_024)))
        }

        #expect(!outcome.ok)
        #expect(outcome.status == .blocked)
        #expect(outcome.summary.contains("typed input exceeded the 128-byte Capability limit"))
        #expect(await probe.startCount() == 0)
    }

    @Test func directBindingUsesCapabilityDurationInsteadOfLocalDefault() async {
        let fixture = directFixture(constraints: [
            .init(kind: .maximumDurationSeconds, value: "0.05"),
        ])
        let probe = InvocationProbe()
        // A 30 s worker against a 0.05 s capability deadline: the elapsed
        // bound below proves the DEADLINE returned (a full wait would be
        // ≥ 30 s) while carrying seconds of load slack instead of the old
        // 1 s-vs-0.9 s margin that flipped under a saturated pool. The
        // abandoned asyncAfter block is inert — nothing awaits it.
        let runtime = runtime(bindings: [delayedBinding(
            fixture.operation,
            delay: 30,
            probe: probe)])

        let startedAt = Date()
        let outcome = await AbilityTurnContext.$snapshot.withValue(fixture.snapshot) {
            await runtime.dispatch(
                name: fixture.invocation,
                argumentsJSON: #"{"payload":"small"}"#)
        }

        #expect(Date().timeIntervalSince(startedAt) < 5)
        #expect(!outcome.ok)
        #expect(outcome.summary.contains("didn't finish"))
        #expect(await probe.startCount() == 1)
    }

    @Test func cognitivePrimitiveRejectsOversizedInputAtItsMachineBoundary() async {
        let capabilityID = CapabilityID("tests.cognitive-payload")
        let capability = CapabilitySchema(
            id: capabilityID,
            title: "Cognitive payload",
            summary: "Bound cognitive input.",
            effect: .none,
            constraints: [.init(kind: .maximumPayloadBytes, value: "128")])
        let skill = SkillSchema(
            id: "writing.compose-draft",
            title: "Compose Draft",
            summary: "Compose a draft.",
            kind: .cognitive,
            requirements: .init(capabilities: [capabilityID]),
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "compose_draft"))
        let package = abilityPackage(
            packageID: "tests.cognitive-payload",
            abilityID: .writing,
            skills: [skill],
            capabilities: [capability])
        let snapshot = runtimeSnapshot(
            package: package,
            operations: [.init(
                adapterID: "tests.adapter",
                operation: "publish_cognitive_capability",
                capabilities: [capabilityID])])
        let runtime = runtime(bindings: [])

        let outcome = await AbilityTurnContext.$snapshot.withValue(snapshot) {
            await runtime.dispatch(
                name: "compose_draft",
                argumentsJSON: json("request", String(repeating: "draft ", count: 100)))
        }

        #expect(snapshot.skill(invocationName: "compose_draft")?.availability.readiness == .ready)
        #expect(!outcome.ok)
        #expect(outcome.status == .blocked)
        #expect(outcome.summary.contains("typed input exceeded the 128-byte Capability limit"))
    }

    @Test func workflowRejectsOversizedTopLevelInputBeforeFirstStep() async {
        let fixture = workflowFixture(constraints: [
            .init(kind: .maximumPayloadBytes, value: "128"),
        ])
        let probe = InvocationProbe()
        let runtime = runtime(bindings: [immediateBinding(
            fixture.childOperation,
            probe: probe)])

        let outcome = await AbilityTurnContext.$snapshot.withValue(fixture.snapshot) {
            await runtime.dispatch(
                name: fixture.invocation,
                argumentsJSON: json("request", String(repeating: "workflow ", count: 100)))
        }

        #expect(fixture.snapshot.skill(invocationName: fixture.invocation)?
            .availability.readiness == .ready)
        #expect(!outcome.ok)
        #expect(outcome.status == .blocked)
        #expect(outcome.summary.contains("typed input exceeded the 128-byte Capability limit"))
        #expect(await probe.startCount() == 0)
    }

    @Test func workflowUsesCapabilityDurationAcrossItsWholeStateMachine() async {
        let fixture = workflowFixture(constraints: [
            .init(kind: .maximumDurationSeconds, value: "0.05"),
        ])
        let probe = InvocationProbe()
        // Same margin arithmetic as the direct-binding test above: 30 s
        // worker, 0.05 s cap, < 5 s bound — deadline-return proven with load
        // slack instead of a sub-second guess.
        let runtime = runtime(bindings: [delayedBinding(
            fixture.childOperation,
            delay: 30,
            probe: probe)])

        let startedAt = Date()
        let outcome = await AbilityTurnContext.$snapshot.withValue(fixture.snapshot) {
            await runtime.dispatch(
                name: fixture.invocation,
                argumentsJSON: #"{"request":"small"}"#)
        }

        #expect(Date().timeIntervalSince(startedAt) < 5)
        #expect(!outcome.ok)
        #expect(outcome.summary.contains("did not finish"))
        #expect(await probe.startCount() == 1)
    }

    private struct DirectFixture {
        var snapshot: AbilityRuntimeSnapshot
        var invocation: String
        var operation: String
    }

    private func directFixture(
        constraints: [CapabilityConstraint]
    ) -> DirectFixture {
        let capabilityID = CapabilityID("tests.direct-execution")
        let operation = "constrained_direct"
        let invocation = "run_constrained_direct"
        let capability = CapabilitySchema(
            id: capabilityID,
            title: "Direct execution",
            summary: "Bound direct adapter execution.",
            effect: .read,
            constraints: constraints)
        let skill = SkillSchema(
            id: "tests.constraints.direct",
            title: "Constrained Direct",
            summary: "Run a constrained direct binding.",
            kind: .effectful,
            requirements: .init(capabilities: [capabilityID]),
            execution: .init(
                kind: .binding,
                bindings: [.init(adapterID: "tests.adapter", operation: operation)]),
            modelExposure: .init(invocationName: invocation))
        let package = abilityPackage(
            packageID: "tests.direct-constraints",
            abilityID: "tests.constraints",
            skills: [skill],
            capabilities: [capability])
        let snapshot = runtimeSnapshot(
            package: package,
            operations: [.init(
                adapterID: "tests.adapter",
                operation: operation,
                capabilities: [capabilityID])])
        return DirectFixture(
            snapshot: snapshot,
            invocation: invocation,
            operation: operation)
    }

    private struct WorkflowFixture {
        var snapshot: AbilityRuntimeSnapshot
        var invocation: String
        var childOperation: String
    }

    private func workflowFixture(
        constraints: [CapabilityConstraint]
    ) -> WorkflowFixture {
        let capabilityID = CapabilityID("tests.workflow-execution")
        let invocation = "run_constrained_workflow"
        let childOperation = "constrained_workflow_step"
        let capability = CapabilitySchema(
            id: capabilityID,
            title: "Workflow execution",
            summary: "Bound a complete workflow execution.",
            effect: .read,
            constraints: constraints)
        let workflow = SkillSchema(
            id: "coding.test-constrained-workflow",
            title: "Constrained Workflow",
            summary: "Run one constrained workflow.",
            kind: .workflow,
            requirements: .init(capabilities: [capabilityID]),
            execution: .init(
                kind: .stateMachine,
                steps: [.init(id: "run", operation: childOperation)]),
            modelExposure: .init(invocationName: invocation))
        let child = SkillSchema(
            id: "coding.test-constrained-step",
            title: "Constrained Step",
            summary: "Run the workflow's local step.",
            kind: .effectful,
            execution: .init(
                kind: .binding,
                bindings: [.init(
                    adapterID: "tests.adapter",
                    operation: childOperation)]),
            modelExposure: .init(invocationName: childOperation))
        let package = abilityPackage(
            packageID: "tests.workflow-constraints",
            abilityID: .coding,
            skills: [workflow, child],
            capabilities: [capability])
        let snapshot = runtimeSnapshot(
            package: package,
            operations: [.init(
                adapterID: "tests.adapter",
                operation: childOperation,
                capabilities: [capabilityID])])
        return WorkflowFixture(
            snapshot: snapshot,
            invocation: invocation,
            childOperation: childOperation)
    }

    private func abilityPackage(
        packageID: PackageID,
        abilityID: AbilityID,
        skills: [SkillSchema],
        capabilities: [CapabilitySchema]
    ) -> MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: packageID,
                version: "1.0.0",
                publisher: "tests",
                summary: "Capability execution fixture."),
            ability: .init(
                id: abilityID,
                title: "Constraint Fixture",
                summary: "Capability execution fixture.",
                tint: "#123456",
                skills: skills.map(\.id)),
            skills: skills,
            capabilities: capabilities)
    }

    private func runtimeSnapshot(
        package: MaryAbilityPackage,
        operations: [InstalledAdapterBinding]
    ) -> AbilityRuntimeSnapshot {
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/constraint-fixture.mary"),
            validation: .init(),
            rawData: Data())
        let manifest = InstalledAdapterManifest(
            adapterID: "tests.adapter",
            title: "Test Adapter",
            transport: .native,
            claimCoverage: .incremental,
            operations: operations)
        return AbilityRuntimeSnapshot(
            records: [record],
            validation: .init(),
            adapterManifests: [manifest])
    }

    private func runtime(bindings: [SkillBinding]) -> AbilityRuntime {
        AbilityRuntime(
            plugins: [],
            standalone: bindings,
            executionLog: AbilityExecutionLog(),
            ambient: AmbientContextStore(),
            passages: PassageRegistry()) {
                AbilityExecutionContext(projects: [:])
            }
    }

    private func immediateBinding(
        _ name: String,
        probe: InvocationProbe
    ) -> SkillBinding {
        SkillBinding(
            name: name,
            description: "Test binding.",
            parameters: [.init(
                name: "payload",
                type: "string",
                description: "Payload.",
                required: false)],
            access: .read,
            backing: .native { _, _ in
                await probe.recordStart()
                return SkillOutcome(ok: true, summary: "ran")
            })
    }

    private func delayedBinding(
        _ name: String,
        delay: TimeInterval,
        probe: InvocationProbe
    ) -> SkillBinding {
        SkillBinding(
            name: name,
            description: "Delayed test binding.",
            access: .read,
            backing: .native { _, _ in
                await probe.recordStart()
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        continuation.resume()
                    }
                }
                return SkillOutcome(ok: true, summary: "late result")
            })
    }

    private func json(_ key: String, _ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [key: value])
        return String(data: data, encoding: .utf8)!
    }
}

private actor InvocationProbe {
    private var starts = 0

    func recordStart() { starts += 1 }
    func startCount() -> Int { starts }
}
