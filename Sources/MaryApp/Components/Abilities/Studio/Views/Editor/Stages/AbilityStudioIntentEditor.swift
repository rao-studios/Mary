import MaryBrain
import SwiftUI

struct AbilityStudioIntentEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        AbilityStudioStageScroll(
            title: "How should Mary recognize and use it?",
            introduction: "Routing is a closed predicate graph. Descriptive prose remains inspector metadata; executable selection comes from these typed triggers and rules.") {
            AbilityStudioEditorSection("Vocabulary", symbol: "text.bubble") {
                AbilityStudioTagEditor(
                    title: "Aliases",
                    path: "ability.aliases",
                    values: package.ability.aliases) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.aliases = values }
                }
                AbilityStudioTagEditor(
                    title: "Trigger tokens",
                    path: "ability.triggers.tokens",
                    values: package.ability.triggers.tokens) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.triggers.tokens = values }
                }
                AbilityStudioTagEditor(
                    title: "Trigger phrases",
                    path: "ability.triggers.phrases",
                    values: package.ability.triggers.phrases) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.triggers.phrases = values }
                }
                AbilityStudioTagEditor(
                    title: "Negative tokens",
                    path: "ability.triggers.negativeTokens",
                    values: package.ability.triggers.negativeTokens) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.triggers.negativeTokens = values }
                }
                AbilityStudioTagEditor(
                    title: "Intent aliases",
                    path: "ability.triggers.intentAliases",
                    values: package.ability.triggers.intentAliases) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.triggers.intentAliases = values }
                }
            }

            AbilityStudioEditorSection("Operating policy annotations", symbol: "list.bullet.clipboard") {
                Text("These phrases help people understand the package. They are never imported as prompt instructions or executable policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AbilityStudioStringListEditor(
                    title: "Phases",
                    path: "ability.operatingPolicy.phases",
                    values: package.ability.operatingPolicy.phases) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.operatingPolicy.phases = values }
                }
                AbilityStudioStringListEditor(
                    title: "Guardrails",
                    path: "ability.operatingPolicy.guardrails",
                    values: package.ability.operatingPolicy.guardrails) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.operatingPolicy.guardrails = values }
                }
                AbilityStudioStringListEditor(
                    title: "Success signals",
                    path: "ability.operatingPolicy.successSignals",
                    values: package.ability.operatingPolicy.successSignals) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.operatingPolicy.successSignals = values }
                }
                AbilityStudioStringListEditor(
                    title: "Stop conditions",
                    path: "ability.operatingPolicy.stopConditions",
                    values: package.ability.operatingPolicy.stopConditions) {
                    let values = $0
                    model.mutateDraftPackage { $0.ability.operatingPolicy.stopConditions = values }
                }
                AbilityStudioTagEditor(
                    title: "Supporting Abilities",
                    path: "ability.operatingPolicy.defaultSupportingAbilities",
                    values: package.ability.operatingPolicy.defaultSupportingAbilities.map(\.rawValue)) { values in
                    model.mutateDraftPackage {
                        $0.ability.operatingPolicy.defaultSupportingAbilities = values.map(AbilityID.init)
                    }
                }
            }

            AbilityStudioEditorSection("Routing rules", symbol: "arrow.triangle.branch") {
                AbilityStudioRoutingPolicyEditor(
                    policy: package.ability.routing,
                    path: "ability.routing") { policy in
                    model.mutateDraftPackage { $0.ability.routing = policy }
                }
            }
        }
    }
}
