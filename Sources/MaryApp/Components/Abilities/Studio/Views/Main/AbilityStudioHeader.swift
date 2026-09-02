//
//  AbilityStudioHeader.swift
//  Mary
//
//  WHAT: Ability name, role, cost, export/import/advanced, Save/Revert.
//  IN:   AbilityStudioView shell.
//  OUT:  mutateDraftPackage (title) / mutateAuthoringDocument (paradigm).
//  PIN:  Mirrors Home's header bar — MaryMark, italic serif title, bare symbols.
//        Below the compact span, trailing controls fold behind ViewThatFits:
//        paradigm becomes an icon, the cost detail moves into its `.help`,
//        and export/import/revert collapse into one overflow menu.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioHeader: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @Binding var railCollapsed: Bool
    @Binding var showsAdvanced: Bool
    let cost: AbilityRunCostEstimate?
    let pricePerCall: Double

    var body: some View {
        HStack(spacing: .layer3) {
            StudioIconButton(
                symbol: railCollapsed ? "sidebar.leading" : "sidebar.left",
                help: railCollapsed ? "Show abilities" : "Hide abilities",
                isOn: !railCollapsed
            ) {
                railCollapsed.toggle()
            }

            MaryMark(size: 20)

            StudioField(
                value: package.ability.title,
                placeholder: "Name of ability",
                font: .marySerif(20, weight: .light, italic: true),
                quiet: true
            ) { next in
                let title = next.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                model.mutateDraftPackage { draft in
                    draft.ability.title = title
                    // The Plugin's title is the same claim about the same thing.
                    draft.plugin?.title = title
                }
            }
            .frame(minWidth: 90, maxWidth: 260)
            // A focused field keeps what the user typed, which is right while
            // editing one ability and wrong the moment another is selected.
            // Keying on the package makes it a different field.
            .id(package.package.id)

            ViewThatFits(in: .horizontal) {
                fullTrailing
                compactTrailing
            }
        }
        .padding(.horizontal, .layer5)
        .padding(.vertical, .layer2)
        .background(Paper.page)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.maryBorder).frame(height: 1)
        }
    }

    private var canSave: Bool {
        model.canEditSelectedPackage && model.validation.isValid
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.maryBorder)
            .frame(width: 1, height: 20)
    }

    // MARK: - Full

    private var fullTrailing: some View {
        HStack(spacing: .layer3) {
            paradigmMenu

            Spacer(minLength: .layer3)

            if let cost {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(cost.amount(pricePerCall: pricePerCall))
                        .font(.maryMono(13))
                        .foregroundStyle(
                            cost.total == 0
                                ? Color.maryInk.opacity(0.45)
                                : Color.maryInk)
                    Text(cost.detail)
                        .font(.marySans(9))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
                .fixedSize()
                .help(cost.help)
            }

            if model.hasPendingRegistryUpdate {
                MaryBadge(text: "registry changed", color: .maryError)
                    .help("The registry changed on disk. This draft stays pinned; Revert opens the active version.")
            } else if model.isDirty {
                MaryBadge(text: "unsaved", color: .maryGold)
            }

            divider

            StudioIconButton(
                symbol: "square.and.arrow.up",
                help: "Export this ability as a .mary file",
                isEnabled: model.canEditSelectedPackage,
                action: model.exportPackage)
            StudioIconButton(
                symbol: "square.and.arrow.down",
                help: "Import a .mary file",
                isEnabled: !model.isDirty,
                action: model.importPackage)
            StudioIconButton(
                symbol: "curlybraces",
                help: "Everything else — contracts, fixtures, raw schema",
                isOn: showsAdvanced
            ) {
                showsAdvanced.toggle()
            }

            if model.isDirty {
                divider
                Button("Revert", action: model.revert)
                    .buttonStyle(.maryQuiet)
                    .fixedSize()
                Button(model.isCreatingNewPackage ? "Save & Activate" : "Save", action: model.save)
                    .buttonStyle(.mary)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                    .fixedSize()
                    .help(model.validation.isValid
                          ? "Save activates this ability for the next turn."
                          : "Fix the errors in Advanced before saving.")
            }
        }
    }

    // MARK: - Compact

    /// The narrow fallback: paradigm shrinks to its icon, the cost detail
    /// moves into `.help`, the "unsaved" badge drops (Save already says so),
    /// and export/import fold into one overflow menu. Advanced and Save
    /// stay — they are the two actions a narrow window still needs at hand.
    private var compactTrailing: some View {
        HStack(spacing: .layer2) {
            compactParadigmButton

            Spacer(minLength: .layer2)

            if let cost {
                Text(cost.amount(pricePerCall: pricePerCall))
                    .font(.maryMono(12))
                    .foregroundStyle(
                        cost.total == 0
                            ? Color.maryInk.opacity(0.45)
                            : Color.maryInk)
                    .lineLimit(1)
                    .help("\(cost.detail) — \(cost.help)")
            }

            if model.hasPendingRegistryUpdate {
                MaryBadge(text: "registry changed", color: .maryError)
                    .help("The registry changed on disk. This draft stays pinned; Revert opens the active version.")
            }

            StudioIconButton(
                symbol: "curlybraces",
                help: "Everything else — contracts, fixtures, raw schema",
                isOn: showsAdvanced
            ) {
                showsAdvanced.toggle()
            }

            MaryOverflowMenu(help: "Export, import") {
                Button("Export…", action: model.exportPackage)
                    .disabled(!model.canEditSelectedPackage)
                Button("Import…", action: model.importPackage)
                    .disabled(model.isDirty)
            }

            if model.isDirty {
                Button("Revert", action: model.revert)
                    .buttonStyle(.maryQuiet)
                    .lineLimit(1)
                Button(model.isCreatingNewPackage ? "Save & Activate" : "Save", action: model.save)
                    .buttonStyle(.mary)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                    .lineLimit(1)
                    .help(model.validation.isValid
                          ? "Save activates this ability for the next turn."
                          : "Fix the errors in Advanced before saving.")
            }
        }
    }

    // MARK: - Paradigm

    /// Paradigm goes through the authoring document, not the fast path: the
    /// paradigm validator can refuse the change (a discipline may not carry a
    /// Plugin), and its verdict belongs in `status` rather than in a broken draft.
    private func paradigmPicker<LabelContent: View>(@ViewBuilder label: () -> LabelContent) -> some View {
        Menu {
            ForEach(AbilityParadigm.allCases, id: \.self) { paradigm in
                Button {
                    model.mutateAuthoringDocument { document in
                        try document.updateAbility { $0.paradigm = paradigm }
                    }
                } label: {
                    Label(paradigm.label, systemImage: AbilityParadigmPresentation(paradigm).symbol)
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(AbilityParadigmPresentation(package.paradigm).explanation)
    }

    private var paradigmMenu: some View {
        paradigmPicker {
            HStack(spacing: 5) {
                Image(systemName: AbilityStudioLabels.roleSymbol(package))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.maryInk.opacity(0.55))
                Text(AbilityStudioLabels.role(package))
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.78))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
            }
            .padding(.horizontal, .layer2)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.maryFill))
        }
        .layoutPriority(-1)
    }

    private var compactParadigmButton: some View {
        paradigmPicker {
            Image(systemName: AbilityStudioLabels.roleSymbol(package))
                .font(.system(size: 12))
                .foregroundStyle(Color.maryInk.opacity(0.6))
                .frame(width: 26, height: 26)
        }
    }
}
