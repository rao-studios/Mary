//
//  RuntimePrimitiveIsolationTests.swift
//  MaryFoundationTests
//
//  WHAT: Packages cannot bind, workflow, or invoke host-owned runtime primitives.
//  OUT:  AbilityPackageValidator reserved-runtime-operation / reserved-runtime-invocation
//

import Testing
@testable import MaryFoundation

@Suite struct RuntimePrimitiveIsolationTests {
    private func package(with skill: SkillSchema) -> MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: "tests.runtime-primitive-isolation",
                version: "1.0.0",
                publisher: "tests",
                summary: "Runtime primitive isolation fixture."),
            ability: .init(
                id: "tests.runtime-primitive-isolation",
                title: "Runtime primitive isolation",
                summary: "Runtime primitive isolation fixture.",
                tint: "#123456",
                skills: [skill.id]),
            skills: [skill])
    }

    @Test func packageBindingsCannotClaimHostRuntimePrimitives() {
        for operation in RuntimePrimitiveOperations.names {
            let skill = SkillSchema(
                id: "tests.runtime-primitive-isolation.binding",
                title: "Reserved binding",
                summary: "Attempts to claim a host-owned primitive.",
                kind: .effectful,
                execution: .init(
                    kind: .binding,
                    bindings: [.init(adapterID: "mac", operation: operation)]),
                modelExposure: .init(enabled: false))

            let validation = AbilityPackageValidator.validate(package(with: skill))
            #expect(
                validation.issues.contains {
                    $0.code == "reserved-runtime-operation"
                        && $0.path.hasSuffix("execution.bindings[0].operation")
                },
                "\(operation) must remain host-owned: \(validation.issues)")
        }
    }

    @Test func packageWorkflowsAndInvocationNamesCannotClaimRuntimePrimitives() {
        let workflow = SkillSchema(
            id: "tests.runtime-primitive-isolation.workflow",
            title: "Reserved workflow",
            summary: "Attempts to compose a host-owned primitive.",
            kind: .workflow,
            execution: .init(
                kind: .stateMachine,
                steps: [.init(id: "execute", operation: "run_shell")]),
            modelExposure: .init(invocationName: "confirm_pending_skill"))

        let validation = AbilityPackageValidator.validate(package(with: workflow))
        #expect(validation.issues.contains {
            $0.code == "reserved-runtime-operation"
                && $0.path.hasSuffix("execution.steps[0].operation")
        })
        #expect(validation.issues.contains {
            $0.code == "reserved-runtime-invocation"
                && $0.path.hasSuffix("modelExposure.invocationName")
        })
    }
}
