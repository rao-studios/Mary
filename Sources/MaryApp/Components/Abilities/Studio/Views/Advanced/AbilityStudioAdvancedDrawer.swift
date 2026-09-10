//
//  AbilityStudioAdvancedDrawer.swift
//  Mary
//
//  WHAT: Everything the three panes leave out — and it is editable, not a viewer.
//  IN:   AbilityStudioView, toggled by the header's curlybraces.
//  OUT:  the same mutation seams the panes use.
//  PIN:  Only Issues and Provider are read-only: they report the frozen
//        registry, not the draft.
//

import MaryBrain
import SwiftUI

/// One collapsible section. The drawer is long, so everything starts closed
/// except what the author just asked for.
struct AbilityStudioAdvancedSection<Content: View>: View {
    let title: String
    var count: String?
    var startsOpen: Bool = false
    @ViewBuilder var content: Content

    @State private var isOpen: Bool?

    private var open: Bool { isOpen ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isOpen = !open
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(title)
                        .font(.marySans(11.5))
                        .foregroundStyle(Color.maryInk.opacity(0.82))
                    Spacer(minLength: .layer2)
                    if let count {
                        Text(count)
                            .font(.maryMono(9.5))
                            .foregroundStyle(Color.maryInk.opacity(0.4))
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: .layer3) { content }
                    .padding(.horizontal, 7)
                    .padding(.top, 3)
                    .padding(.bottom, .layer3)
            }
        }
    }
}

@MainActor
struct AbilityStudioAdvancedDrawer: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let onFocus: (AbilityStudioPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.maryBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    AbilityStudioIssuesSection(model: model, onFocus: onFocus)

                    if let recipe = model.selectedRecipe {
                        AbilityStudioAdvancedSection(
                            title: "Recipe step",
                            count: model.expandedRecipeStepID ?? "select a row"
                        ) {
                            AbilityStudioRecipeStepSection(model: model, recipe: recipe)
                        }
                    }

                    AbilityStudioAdvancedSection(
                        title: "Depends on",
                        count: "\(package.dependencies.count)"
                    ) {
                        AbilityStudioDependenciesSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Capabilities",
                        count: "\(package.capabilities.count)"
                    ) {
                        AbilityStudioCapabilitiesSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Value types",
                        count: "\(package.valueTypes.count)"
                    ) {
                        AbilityStudioValueTypesSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Interactions",
                        count: "\(package.interactions.count)"
                    ) {
                        AbilityStudioInteractionsSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Perceptions",
                        count: "\(package.perceptions.count)"
                    ) {
                        AbilityStudioPerceptionsSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Thread projections",
                        count: "\(package.threadProjections.count)"
                    ) {
                        AbilityStudioProjectionsSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Routing rehearsals",
                        count: "\(package.fixtures.count)"
                    ) {
                        AbilityStudioFixturesSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(title: "Operating policy") {
                        AbilityStudioOperatingPolicySection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(
                        title: "Eligible when",
                        count: package.ability.routing.eligibility == nil ? "any" : "rule"
                    ) {
                        AbilityStudioEligibilitySection(model: model, package: package)
                    }

                    if package.corpus != nil || package.plugin?.corpus != nil {
                        AbilityStudioAdvancedSection(title: "Project shape") {
                            AbilityStudioCorpusSection(package: package)
                        }
                    }

                    AbilityStudioAdvancedSection(title: "Provider & application") {
                        AbilityStudioProviderSection(model: model, package: package)
                    }

                    AbilityStudioAdvancedSection(title: "Schema") {
                        AbilityStudioSchemaSection(model: model)
                    }
                }
                .padding(.vertical, .layer2)
                .padding(.horizontal, 7)
            }
            .scrollIndicators(.never)
        }
        .background(Paper.page)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.maryBorder).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            SectionLabel("Advanced")
            Spacer()
            Text(package.package.id.rawValue)
                .font(.maryMono(9.5))
                .foregroundStyle(Color.maryInk.opacity(0.35))
                .textSelection(.enabled)
        }
        .padding(.horizontal, .layer3)
        .padding(.vertical, .layer3)
    }
}
