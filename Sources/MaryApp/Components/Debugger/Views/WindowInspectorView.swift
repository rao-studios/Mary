//
//  WindowInspectorView.swift
//  Mary
//
//  The drill-in for ONE window — the tile the user actually tapped, not the
//  app it belongs to.
//
//  THE FAILURE THIS FIXES: the minimap showed two Pages tiles for one
//  document, one of them featureless white, and tapping either opened the
//  identical per-app perception card. `selectedWindowID` was recorded on tap
//  and then spent on a selection fill and one branch condition — so the two
//  tiles were, by construction, indistinguishable. Everything here is a
//  property the sweep already had and threw away at the view boundary.
//
//  DOCTRINE: nothing is coalesced. A nil title renders AS a missing title,
//  never as the app's name — that substitution is what let a ghost window
//  wear a real window's identity. And windows are NEVER deduped: merging the
//  duplicate tiles would hide the very thing this view exists to identify.
//

import SwiftUI
import MaryRuntime

struct WindowInspectorView: View {
    let tile: WindowTile
    /// Degraded mode enumerates APPS, not windows — there is no SCWindow
    /// behind the tile, so frame/layer/activity are unknown rather than zero.
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
                    // Title FIRST and RAW: two windows of one document differ
                    // by title before they differ by anything else.
                    row("title", tile.title ?? "— (no title reported)",
                        muted: tile.title == nil)
                    row("window id", "\(tile.id)")
                    row("pid", "\(tile.pid)")
                    // Origin AND size, separately: identical frames on two
                    // tiles means window tabbing, and only the origin says so.
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

    /// On-screen and active are DIFFERENT questions. The SCK header is
    /// explicit that Stage Manager produces off-screen-but-active windows, so
    /// "other Space, active" is a healthy window and "other Space, inactive"
    /// beside a capture that drew nothing is the husk shape.
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
