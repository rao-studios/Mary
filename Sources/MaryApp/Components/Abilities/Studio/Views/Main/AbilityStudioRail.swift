//
//  AbilityStudioRail.swift
//  Mary
//
//  WHAT: The installed abilities, and which one is being edited.
//  IN:   AbilityStudioView shell.
//  OUT:  model.requestSelect — a dirty draft asks before it is left behind.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioRail: View {
    @ObservedObject var model: AbilityStudioViewModel
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.snapshot.records) { record in
                        row(record)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, .layer2)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Color.maryBorder)

            HStack(spacing: .layer2) {
                Button("New", action: onNew)
                    .buttonStyle(.maryQuiet)
                    .disabled(model.isDirty)
                Button("Reload", action: model.reload)
                    .buttonStyle(.maryQuiet)
                    .disabled(model.isDirty)
                Spacer(minLength: 0)
            }
            .font(.marySans(11))
            .padding(.horizontal, 7)
            .padding(.vertical, .layer2)
        }
        .background(Paper.page)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.maryBorder).frame(width: 1)
        }
    }

    private func row(_ record: AbilityPackageRecord) -> some View {
        let isSelected = record.id == model.selectedPackageID
        return Button {
            model.requestSelect(record.id)
        } label: {
            AbilityRowView(
                package: record.package,
                isSelected: isSelected
            ) {
                if isSelected, model.isDirty {
                    MaryBadge(text: "unsaved", color: .maryGold)
                }
            }
        }
        .buttonStyle(.plain)
        .help(AbilityStudioLabels.provenanceDetail(record))
    }
}
