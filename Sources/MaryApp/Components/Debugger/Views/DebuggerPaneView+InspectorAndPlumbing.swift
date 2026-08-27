//
//  DebuggerPaneView+InspectorAndPlumbing.swift
//

import MaryBrain
import SwiftUI
import MaryRuntime

extension DebuggerPaneView {

    // MARK: - Degraded banner

    func degradedBanner(_ reason: DegradedReason) -> some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                switch reason {
                case .screenRecordingDenied:
                    Text("Mary can only see app icons. Grant Screen Recording for live thumbnails — macOS applies it after relaunch.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Screen Recording settings") {
                        PermissionsCenter.openSettingsPane(
                            PermissionItem(kind: .screenRecording, status: .denied))
                    }
                    .buttonStyle(.maryQuiet)
                case .enumerationFailed(let message):
                    Text("Window enumeration failed — showing app icons only. \(message)")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Inspector

    /// The tapped tile, resolved from the WHOLE sweep rather than the
    /// filtered view: a tab change must never strand the selection on a tile
    /// the pane no longer renders, leaving the inspector talking about
    /// nothing. `vm.model.groups`, never `visibleGroups`.
    ///
    /// No dedupe anywhere in this path — two tiles for one document is the
    /// FINDING, and coalescing them would delete it.
    var selectedTile: WindowTile? {
        guard let selectedWindowID else { return nil }
        return vm.model.groups
            .lazy
            .flatMap(\.windows)
            .first { $0.id == selectedWindowID }
    }

    /// Degraded mode's tiles stand for APPS — the window inspector says so
    /// rather than rendering zeros as measurements.
    var isDegradedMode: Bool {
        if case .degraded = vm.model.mode { return true }
        return false
    }

    @ViewBuilder
    var inspectorSlot: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            SectionLabel("Inspector")
            // The window the user tapped, IN ADDITION to (never instead of)
            // the per-app perception card below — two Pages tiles produce the
            // same world card by construction, which is exactly why they were
            // indistinguishable.
            if let tile = selectedTile {
                WindowInspectorView(tile: tile, isDegraded: isDegradedMode)
            }
            if let world = selectedWorld.flatMap(PerceptionWorld.init(rawValue:)),
               let card = perceptionVM.cards.first(where: { $0.world == world }) {
                PerceptionInspectorView(
                    card: card,
                    focus: perceptionVM.focus,
                    onTogglePin: { togglePin(world) },
                    onCopy: { copyReport(card) })
            } else if selectedWindowID != nil {
                MaryCard(padding: 12) {
                    Text("Not pinnable — Mary has no eyes here. Only applications an installed Ability teaches her to watch are pinnable; the rest render as honest icons.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MaryCard(padding: 12) {
                    Text("Select a window — watched apps open the perception inspector.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Pin plumbing

    /// The pin never raises the target app (approved UX) — it only steers
    /// the focus arbiter until cleared.
    func togglePin(_ world: PerceptionWorld) {
        perceptionVM.togglePin(world)
    }

    func copyReport(_ card: PerceptionCard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            PerceptionReport.serialize(
                focus: perceptionVM.focus, card: card, at: Date()),
            forType: .string)
    }

    /// Read straight off the tracker's truth (the VM polls it and refreshes
    /// synchronously on toggle). A Center-held mirror was a SECOND copy of
    /// pin state that died with the pane: closing and reopening the split
    /// re-minted an empty Center while the pin kept steering focus, so the
    /// badge vanished from a pin that was still live. One source only.
    func isPinned(_ group: AppTileGroup) -> Bool {
        guard let pinned = perceptionVM.focus.pinned else { return false }
        return PerceptionSnapshotViewModel
            .world(forBundleID: group.bundleID)?.pinKey == pinned.badgeKey
    }

}
