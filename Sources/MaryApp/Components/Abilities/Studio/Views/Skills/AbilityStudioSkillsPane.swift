//
//  AbilityStudioSkillsPane.swift
//  Mary
//
//  WHAT: What this ability can do, in lanes by the ability that defines each skill.
//  IN:   AbilityStudioView.
//  OUT:  selection → AbilityStudioSkillDetail; lineage → AbilityStudioLineageOverlay.
//

import MaryBrain
import MaryRuntime
import SwiftUI

@MainActor
struct AbilityStudioSkillsPane: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    @State private var collapsedLanes: Set<AbilityID> = []
    @State private var showsDrafter = false

    private var bench: AbilityStudioSkillBench {
        AbilityStudioSkillBench(
            draft: package,
            snapshot: model.snapshot,
            selectedRecipe: model.selectedRecipe)
    }

    private var selectedTile: AbilityStudioSkillTile? {
        guard let id = model.selectedSkillID else { return nil }
        return bench.lanes.flatMap(\.tiles).first { $0.id == id }
    }

    var body: some View {
        let bench = bench
        StudioPane("Skills") {
            if canDraft {
                Button {
                    showsDrafter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("Draft a skill").font(.marySans(10))
                    }
                    .foregroundStyle(Color.maryGold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.maryGold.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Say what this ability should be able to do; Seer drafts the blocks.")
            }
        } content: {
            VStack(alignment: .leading, spacing: .layer3) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: .layer4) {
                        ForEach(bench.lanes) { lane in
                            self.lane(lane)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.never)

                if let selectedTile {
                    AbilityStudioSkillDetail(
                        model: model,
                        tile: selectedTile,
                        draft: package,
                        onOpenOwner: openOwner)
                }
            }
        }
        .sheet(isPresented: $showsDrafter) {
            AbilityStudioDraftSkillSheet(model: model, package: package)
        }
    }

    /// Only an expertise with macUI hands can be given more of them. Whether
    /// Seer can answer right now is a transient network condition, reported by
    /// the sheet at the moment of use rather than used to hide the door.
    private var canDraft: Bool {
        package.plugin?.adapters.contains { $0.engine == .macUI } == true
    }

    // MARK: - Lane

    @ViewBuilder
    private func lane(_ lane: AbilityStudioSkillLane) -> some View {
        let isCollapsed = collapsedLanes.contains(lane.abilityID)
            || (lane.isCollapsedByDefault && !collapsedLanes.contains(lane.abilityID)
                && !expandedByDefault.contains(lane.abilityID))

        VStack(alignment: .leading, spacing: 0) {
            if !isCollapsed {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: .layer2) {
                        ForEach(lane.tiles) { tile in
                            AbilityStudioSkillTileView(
                                tile: tile,
                                isSelected: tile.id == model.selectedSkillID
                            ) {
                                model.selectedSkillID =
                                    model.selectedSkillID == tile.id ? nil : tile.id
                            }
                            .lineageTile(tile.id)
                        }
                    }
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.never)
            }

            laneLabel(lane, isCollapsed: isCollapsed)
                .lineageLane(lane.abilityID)
        }
        .overlayPreferenceValue(AbilityStudioLineageAnchorKey.self) { anchors in
            AbilityStudioLineageOverlay(
                anchors: anchors,
                tileOwners: Dictionary(
                    lane.tiles.map {
                        ($0.id, (ability: $0.ownerAbilityID,
                                 tint: $0.ownerTint,
                                 isUsed: $0.isUsedBySelectedRecipe))
                    },
                    uniquingKeysWith: { first, _ in first }))
        }
    }

    private func laneLabel(
        _ lane: AbilityStudioSkillLane,
        isCollapsed: Bool
    ) -> some View {
        Button {
            toggle(lane)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.maryAbilityTint(lane.tint))
                    .frame(width: 7, height: 7)
                Text(lane.title)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.62))
                if let note = lane.note {
                    Text("· \(note)")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.38))
                }
                if isCollapsed {
                    Text("· \(lane.tiles.count)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.38))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.leading, 2)
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show these skills" : "Hide these skills")
    }

    /// Optional-dependency lanes start collapsed; opening one is remembered for
    /// as long as the pane is on screen.
    @State private var expandedByDefault: Set<AbilityID> = []

    private func toggle(_ lane: AbilityStudioSkillLane) {
        if lane.isCollapsedByDefault {
            if expandedByDefault.contains(lane.abilityID) {
                expandedByDefault.remove(lane.abilityID)
            } else {
                expandedByDefault.insert(lane.abilityID)
            }
            return
        }
        if collapsedLanes.contains(lane.abilityID) {
            collapsedLanes.remove(lane.abilityID)
        } else {
            collapsedLanes.insert(lane.abilityID)
        }
    }

    private func openOwner(_ abilityID: AbilityID) {
        guard let record = model.snapshot.records.first(where: {
            $0.package.ability.id == abilityID
        }) else { return }
        model.requestSelect(record.id)
    }
}
