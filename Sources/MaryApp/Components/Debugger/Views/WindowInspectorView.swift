//
//  WindowInspectorView.swift
//  Mary
//
//  WHAT: Drill-in for the tapped window tile (not the app).
//  IN:   DebuggerPaneView
//  PIN:  Nothing coalesced. Nil title stays missing. Windows are never deduped.
//

import SwiftUI
import MaryRuntime

struct WindowInspectorView: View {
    let tile: WindowTile
    /// Degraded mode enumerates apps, not windows — no SCWindow, so frame/layer/activity unknown.
    let isDegraded: Bool

    var body: some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                SectionLabel("This window")
                if isDegraded {
                    Text("Screen Recording is off, so this tile stands for an APP, not a window — there is no frame, layer, or capture behind it.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    row("app", tile.appName)
                    row("pid", "\(tile.pid)")
                } else {
                    // Title first and raw: two windows of one document differ by title first.
                    row("title", tile.title ?? "— (no title reported)",
                        muted: tile.title == nil)
                    row("window id", "\(tile.id)")
                    row("pid", "\(tile.pid)")
                    // Origin and size separately: identical frames often mean window tabbing.
                    row("origin", "x \(number(tile.frame.origin.x)), y \(number(tile.frame.origin.y))")
                    row("size", "\(number(tile.frame.width)) × \(number(tile.frame.height))")
                    row("space", spaceLine)
                    row("layer", "\(tile.layer)")
                    row("capture", tile.captureState.label,
                        alarming: isAlarming(tile.captureState))
                    row("thumbnail", tile.capturedAt.map {
                        "\(PerceptionReport.ageString(Date().timeIntervalSince($0))) old"
                    } ?? "none held")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// On-screen vs active are different (Stage Manager: off-screen-but-active is healthy).
    private var spaceLine: String {
        let place = tile.isOnActiveSpace ? "on the active Space" : "on another Space / hidden"
        return place + (tile.isActive ? ", active" : ", not active")
    }

    private func isAlarming(_ state: WindowCaptureState) -> Bool {
        switch state {
        case .blank, .failed: return true
        case .never, .captured: return false
        }
    }

    private func number(_ value: CGFloat) -> String {
        String(format: "%.0f", value)
    }

    private func row(
        _ label: String, _ value: String, muted: Bool = false, alarming: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.marySans(9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.maryInk.opacity(0.45))
            Text(value)
                .font(.marySans(11))
                .foregroundStyle(
                    alarming ? Color.maryError
                        : muted ? Color.maryInk.opacity(0.5) : Color.maryInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
