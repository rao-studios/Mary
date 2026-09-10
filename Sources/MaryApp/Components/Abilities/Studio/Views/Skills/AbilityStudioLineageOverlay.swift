//
//  AbilityStudioLineageOverlay.swift
//  Mary
//
//  WHAT: The lines from each skill down to the ability that defines it.
//  IN:   AbilityStudioSkillsPane lanes.
//  OUT:  drawing only.
//  PIN:  Anchors, not arithmetic — tiles scroll and wrap, and the lines have to
//        follow them. This is the picture that answers "where does this ability
//        get its power from".
//

import MaryBrain
import SwiftUI

struct AbilityStudioLineageAnchors: Equatable {
    var tiles: [SkillID: Anchor<CGRect>] = [:]
    var lanes: [AbilityID: Anchor<CGRect>] = [:]
}

struct AbilityStudioLineageAnchorKey: PreferenceKey {
    static let defaultValue = AbilityStudioLineageAnchors()

    static func reduce(
        value: inout AbilityStudioLineageAnchors,
        nextValue: () -> AbilityStudioLineageAnchors
    ) {
        let next = nextValue()
        value.tiles.merge(next.tiles) { _, new in new }
        value.lanes.merge(next.lanes) { _, new in new }
    }
}

extension View {
    func lineageTile(_ id: SkillID) -> some View {
        anchorPreference(key: AbilityStudioLineageAnchorKey.self, value: .bounds) {
            AbilityStudioLineageAnchors(tiles: [id: $0])
        }
    }

    func lineageLane(_ id: AbilityID) -> some View {
        anchorPreference(key: AbilityStudioLineageAnchorKey.self, value: .bounds) {
            AbilityStudioLineageAnchors(lanes: [id: $0])
        }
    }
}

/// Draws one line per tile, in its owner ability's tint, converging on that
/// ability's label. Tiles the selected recipe uses are drawn in the highlight.
struct AbilityStudioLineageOverlay: View {
    let anchors: AbilityStudioLineageAnchors
    /// skill → (owning ability, tint hex, used by the selected recipe)
    let tileOwners: [SkillID: (ability: AbilityID, tint: String, isUsed: Bool)]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, _ in
                // One rail per lane, drawn once. Drawing a full elbow per tile
                // stacks a dozen strokes on the same pixels and reads as a bar.
                for (abilityID, laneAnchor) in anchors.lanes {
                    let lane = proxy[laneAnchor]
                    let members = anchors.tiles.compactMap { skillID, anchor -> (CGRect, Bool)? in
                        guard let owner = tileOwners[skillID],
                              owner.ability == abilityID
                        else { return nil }
                        let rect = proxy[anchor]
                        // A lane label sits under its own tiles; anything else
                        // belongs to a different lane's overlay.
                        guard lane.minY > rect.maxY else { return nil }
                        return (rect, owner.isUsed)
                    }
                    guard !members.isEmpty else { continue }

                    let tint = tileOwners.first { $0.value.ability == abilityID }?.value.tint
                    let color = Color.maryAbilityTint(tint ?? "").opacity(0.4)
                    let railY = members.map(\.0.maxY).max().map { ($0 + lane.minY) / 2 }
                        ?? lane.minY
                    let anchorX = lane.minX + 7
                    let reach = members.map(\.0.midX).max() ?? anchorX

                    var rail = Path()
                    rail.move(to: CGPoint(x: anchorX, y: lane.minY))
                    rail.addLine(to: CGPoint(x: anchorX, y: railY))
                    rail.addLine(to: CGPoint(x: max(anchorX, reach - 4), y: railY))
                    context.stroke(rail, with: .color(color), lineWidth: 1)

                    for (rect, isUsed) in members {
                        var stub = Path()
                        stub.move(to: CGPoint(x: rect.midX, y: rect.maxY))
                        stub.addLine(to: CGPoint(x: rect.midX, y: railY - 4))
                        stub.addQuadCurve(
                            to: CGPoint(x: rect.midX - 4, y: railY),
                            control: CGPoint(x: rect.midX, y: railY))
                        context.stroke(
                            stub,
                            with: .color(isUsed ? Paper.highlight : color),
                            lineWidth: isUsed ? 1.8 : 1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
