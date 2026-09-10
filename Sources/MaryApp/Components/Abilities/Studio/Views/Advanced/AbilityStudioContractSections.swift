//
//  AbilityStudioContractSections.swift
//  Mary
//
//  WHAT: The typed contracts a package declares — capabilities, value types,
//        interactions, perceptions.
//  IN:   Advanced drawer.
//  OUT:  mutateDraftPackage; the panes reference these by id.
//  PIN:  Interactions and perceptions had no editor at all before this. They are
//        here so the drawer's claim — nothing is lost — is actually true.
//

import MaryBrain
import SwiftUI

// MARK: - Shared chrome

/// One declared thing in the drawer: a titled block with its id in mono.
struct AbilityStudioDeclarationCard<Content: View>: View {
    let identifier: String
    var onRemove: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Text(identifier)
                    .font(.maryMono(10))
                    .foregroundStyle(Color.maryInk.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: .layer1)
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.maryInk.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            content
        }
        .padding(.layer3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.maryCard))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.maryBorder, lineWidth: 1))
    }
}

/// A label-and-value line for facts that are read, not edited here.
struct AbilityStudioFactLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: .layer2) {
            Text(label)
                .font(.marySans(9.5))
                .foregroundStyle(Color.maryInk.opacity(0.45))
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Capabilities

@MainActor
struct AbilityStudioCapabilitiesSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if package.capabilities.isEmpty {
            StudioNote("None. A capability is the permission-and-effect contract a skill requires before it may act.")
        }
        ForEach(Array(package.capabilities.enumerated()), id: \.element.id) { index, capability in
            AbilityStudioDeclarationCard(identifier: capability.id.rawValue) {
                StudioField("Called", value: capability.title) { next in
                    model.mutateDraftPackage { $0.capabilities[index].title = next }
                }
                StudioField("Summary", value: capability.summary) { next in
                    model.mutateDraftPackage { $0.capabilities[index].summary = next }
                }
                StudioMenuPicker(
                    label: "Effect",
                    value: capability.effect,
                    options: CapabilityEffect.allCases,
                    title: Self.effectWord
                ) { next in
                    model.mutateDraftPackage { $0.capabilities[index].effect = next }
                }
                if !capability.permissions.isEmpty {
                    AbilityStudioFactLine(
                        label: "Needs",
                        value: capability.permissions
                            .map { AbilityStudioLabels.permission($0.kind) }
                            .joined(separator: ", "))
                }
                if !capability.constraints.isEmpty {
                    AbilityStudioFactLine(
                        label: "Bounded by",
                        value: capability.constraints
                            .map { "\($0.kind.rawValue) \($0.value)" }
                            .joined(separator: ", "))
                }
            }
        }
    }

    /// Effect is the promise about consequences, so it is said as one.
    static func effectWord(_ effect: CapabilityEffect) -> String {
        switch effect {
        case .none: return "changes nothing"
        case .read: return "reads only"
        case .reversibleMutation: return "changes, undoably"
        case .mutation: return "changes"
        case .destructive: return "destroys"
        case .externalCommunication: return "sends outward"
        }
    }
}

// MARK: - Value types

@MainActor
struct AbilityStudioValueTypesSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if package.valueTypes.isEmpty {
            StudioNote("None. Value types name the shapes that travel between skills.")
        }
        ForEach(Array(package.valueTypes.enumerated()), id: \.element.id) { index, valueType in
            AbilityStudioDeclarationCard(identifier: valueType.id.rawValue) {
                StudioField("Called", value: valueType.title) { next in
                    model.mutateDraftPackage { $0.valueTypes[index].title = next }
                }
                StudioField("Summary", value: valueType.summary) { next in
                    model.mutateDraftPackage { $0.valueTypes[index].summary = next }
                }
                AbilityStudioFactLine(label: "Shape", value: valueType.shape.rawValue)
                if !valueType.enumValues.isEmpty {
                    StudioChipEditor(
                        "One of",
                        values: valueType.enumValues
                    ) { next in
                        model.mutateDraftPackage { $0.valueTypes[index].enumValues = next }
                    }
                }
                if !valueType.fields.isEmpty {
                    AbilityStudioFactLine(
                        label: "Fields",
                        value: valueType.fields.map(\.name).joined(separator: ", "))
                }
            }
        }
    }
}

// MARK: - Interactions

@MainActor
struct AbilityStudioInteractionsSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if package.interactions.isEmpty {
            StudioNote("None. An interaction is something the user did that a skill may consume as evidence — a selection, a named target.")
        }
        ForEach(Array(package.interactions.enumerated()), id: \.element.id) { index, interaction in
            AbilityStudioDeclarationCard(identifier: interaction.id.rawValue) {
                StudioField("Called", value: interaction.title) { next in
                    model.mutateDraftPackage { $0.interactions[index].title = next }
                }
                StudioField("Summary", value: interaction.summary) { next in
                    model.mutateDraftPackage { $0.interactions[index].summary = next }
                }
                AbilityStudioFactLine(label: "Carries", value: interaction.valueType.rawValue)
                AbilityStudioFactLine(label: "Owned by", value: interaction.ownership.rawValue)
                AbilityStudioFactLine(
                    label: "Stays fresh",
                    value: "\(Int(interaction.freshnessSeconds))s")
                AbilityStudioFactLine(label: "Privacy", value: interaction.privacy.rawValue)
            }
        }
    }
}

// MARK: - Perceptions

@MainActor
struct AbilityStudioPerceptionsSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if package.perceptions.isEmpty {
            StudioNote("None. A perception is something Mary can observe about the world without being told.")
        }
        ForEach(Array(package.perceptions.enumerated()), id: \.element.id) { index, perception in
            AbilityStudioDeclarationCard(identifier: perception.id.rawValue) {
                StudioField("Called", value: perception.title) { next in
                    model.mutateDraftPackage { $0.perceptions[index].title = next }
                }
                StudioField("Summary", value: perception.summary) { next in
                    model.mutateDraftPackage { $0.perceptions[index].summary = next }
                }
                AbilityStudioFactLine(label: "Carries", value: perception.valueType.rawValue)
                AbilityStudioFactLine(label: "Observed", value: perception.ownership.rawValue)
                AbilityStudioFactLine(
                    label: "Stays fresh",
                    value: "\(Int(perception.freshnessSeconds))s")
            }
        }
    }
}
