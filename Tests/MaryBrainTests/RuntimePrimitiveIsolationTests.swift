import MaryFoundation
import Testing
@testable import MaryBrain

@Suite struct RuntimePrimitiveIsolationTests {
    private func skill(adapterID: AdapterID, operation: String) -> SkillSchema {
        SkillSchema(
            id: "tests.runtime-primitive-isolation.binding",
            title: "Runtime isolation",
            summary: "Runtime compatibility boundary fixture.",
            kind: .effectful,
            execution: .init(
                kind: .binding,
                bindings: [.init(adapterID: adapterID, operation: operation)]),
            modelExposure: .init(enabled: false))
    }

    @Test func primitiveInventoryCannotRealizePackageAuthoredBindings() {
        for operation in RuntimePrimitiveOperations.names {
            let binding = InstalledAdapterBinding(
                adapterID: "mac",
                operation: operation)
            let inventory = InstalledAdapterInventory(
                manifests: [],
                primitiveBindings: [.init(
                    adapter: binding,
                    ownerID: "mac",
                    ownerTitle: "Mac")])

            let result = AbilityAdapterCompatibilityEvaluator.evaluate(
                skill: skill(adapterID: "mac", operation: operation),
                capabilitySchemas: [:],
                inventory: inventory)

            #expect(result.selected == nil)
            #expect(result.reasons.contains { $0.contains("host-owned") || $0.contains("Mary-owned") })
        }
    }

    @Test func reservedNamesStayBlockedEvenIfAManifestAttemptsToPublishThem() {
        let manifest = InstalledAdapterManifest(
            adapterID: "tests.adapter",
            title: "Test Adapter",
            transport: .native,
            operations: [.init(
                adapterID: "tests.adapter",
                operation: "run_shell")])
        let result = AbilityAdapterCompatibilityEvaluator.evaluate(
            skill: skill(adapterID: "tests.adapter", operation: "run_shell"),
            capabilitySchemas: [:],
            inventory: .init(manifests: [manifest], primitiveBindings: []))

        #expect(result.selected == nil)
        #expect(result.reasons.contains { $0.contains("Mary-owned runtime primitive") })
    }

    @Test func manifestBackedNonPrimitiveBindingsRemainCompatible() {
        let operation = "safe_operation"
        let manifest = InstalledAdapterManifest(
            adapterID: "tests.adapter",
            title: "Test Adapter",
            transport: .native,
            operations: [.init(
                adapterID: "tests.adapter",
                operation: operation)])
        let result = AbilityAdapterCompatibilityEvaluator.evaluate(
            skill: skill(adapterID: "tests.adapter", operation: operation),
            capabilitySchemas: [:],
            inventory: .init(manifests: [manifest], primitiveBindings: []))

        #expect(result.selected?.operation == operation)
        #expect(result.reasons.isEmpty)
    }
}
