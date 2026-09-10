//
//  AbilityStudioSkillTileView.swift
//  Mary
//
//  WHAT: One skill on the bench — what it is, who realizes it, whether it runs.
//  IN:   AbilityStudioSkillsPane.
//  OUT:  selection only; edits happen in the detail strip.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioSkillTileView: View {
    let tile: AbilityStudioSkillTile
    let isSelected: Bool
    let onSelect: () -> Void

    private var tint: Color { Color.maryAbilityTint(tile.ownerTint) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(height: 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: .layer1) {
                        Text(tile.title)
                            .font(.marySerif(12))
                            .foregroundStyle(Color.maryInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let readiness = tile.readiness {
                            Circle()
                                .fill(AbilityStudioLabels.readinessColor(readiness))
                                .frame(width: 6, height: 6)
                                .padding(.top, 3)
                                .help(AbilityStudioLabels.readinessWord(readiness))
                        }
                    }
                    if let invocation = tile.invocation {
                        Text(invocation)
                            .font(.maryMono(8.5))
                            .foregroundStyle(Color.maryInk.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: tile.isRecipe
                              ? "point.3.filled.connected.trianglepath.dotted"
                              : AbilityStudioLabels.kindSymbol(tile.kind))
                            .font(.system(size: 8))
                        if let access = AbilityStudioLabels.accessSymbol(tile.access) {
                            Image(systemName: access)
                                .font(.system(size: 8))
                                .foregroundStyle(
                                    tile.access == .confirm
                                        ? Color.maryError
                                        : Color.maryInk.opacity(0.45))
                        }
                        Text(realizationWord)
                            .font(.marySans(8))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                .padding(.horizontal, 7)
                .padding(.top, 6)
                .padding(.bottom, 7)
            }
            .frame(width: 96, height: 74, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.maryCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.maryBorder, lineWidth: 1))
            .overlay(alignment: .bottom) {
                // The selected recipe uses this one.
                if tile.isUsedBySelectedRecipe {
                    Rectangle()
                        .fill(Paper.highlight)
                        .frame(height: 3)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Paper.highlight, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(tile.summary)
    }

    private var realizationWord: String {
        let word = tile.realization.word
        return word.isEmpty ? AbilityStudioLabels.kindWord(tile.kind) : word
    }
}
