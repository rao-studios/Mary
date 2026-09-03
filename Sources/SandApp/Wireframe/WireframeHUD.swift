//
//  WireframeHUD.swift
//  Sand
//
//  WHAT: What the live wireframe actually costs, printed rather than assumed.
//  IN:   AXSnapshotPoller.Stats + the derived ambient artifact
//  OUT:  the stage's top-trailing card
//  PIN:  THE CADENCE IS A CEILING, NOT A FRAME RATE. "Publish rate" is how
//        often the tree actually changed; "Walk" is what one read cost. A
//        poller that asks four times a second and a walk that takes 300 ms is
//        a fact worth seeing, not one worth hiding.
//        No observer-coverage or wake rows: Mary's engine has no observer hub
//        and no wake lane, and a row that always reads "—" is noise.
//
import MaryComputerUse
import SwiftUI

struct WireframeHUD: View {
    @ObservedObject var model: WireframeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.targetName).font(.headline)
            row("Elements", "\(model.stats.nodeCount)")
            row("Walk", walkText)
            row("Snapshot age", ageText)
            row("Publish rate", publishRateText)
            row("Cadence", model.stats.cadence.label)
            row("Walks", "\(model.stats.walks)")
            if model.stats.isTruncated {
                Label("Truncated (budget hit)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            webRow
            detailRows
            ambientRows
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 260, alignment: .leading)
    }

    /// THE AMBIENT ARTIFACT, compactly — what this target contributes to
    /// Mary's tier-0 ambient context. Suppressed entirely while the inspector
    /// is closed (nothing derives it then), so the HUD is unchanged for anyone
    /// not asking. Every row's text comes from `AXAmbientPresentation`, the
    /// same pure model the panel lays out.
    @ViewBuilder
    private var ambientRows: some View {
        if let ambient = model.ambient {
            Divider().padding(.vertical, 2)
            ForEach(AXAmbientPresentation.summaryRows(for: ambient)) { entry in
                row(entry.label, entry.value)
            }
        }
    }

    /// Absent entirely for an app with no web content — most targets are not
    /// browsers, and a row reading "none" on every one of them would be noise.
    /// For the ones that are, this says why a page can be walked and still come
    /// back nearly empty: Mary has no wake lane, so a lazily-built tree may
    /// simply not be there yet.
    @ViewBuilder
    private var webRow: some View {
        if let host = model.stats.webHost, host != .none {
            row("Web host", host.rawValue)
            Text("no wake lane — a lazy page may read empty")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    /// The detail lane made visible — absent until something is zoomed into,
    /// since un-zoomed there is nothing being decorated. `decorated` against
    /// `read` is the honest measure of what a given provider actually
    /// answered: an app that returns nothing shows 0 here rather than looking
    /// like an empty screen.
    @ViewBuilder
    private var detailRows: some View {
        if let detail = model.focusDetail {
            row("Detail", "\(detail.nodes.count)/\(detail.nodesRead) decorated")
            row("Detail read", milliseconds(detail.readDuration))
            if detail.nodesSkipped > 0 {
                row("Detail skipped", "\(detail.nodesSkipped)")
            }
            if detail.isTruncated {
                Label("Detail truncated (budget hit)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var walkText: String {
        guard let duration = model.stats.lastWalkDuration else { return "—" }
        return milliseconds(duration)
    }

    private func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
    }

    private var ageText: String {
        guard let publishedAt = model.stats.publishedAt else { return "—" }
        let age = Date().timeIntervalSince(publishedAt)
        return String(format: "%.2f s", age)
    }

    private var publishRateText: String {
        String(format: "%.0f /s", model.stats.publishHz)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
