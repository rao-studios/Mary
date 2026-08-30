//
//  LifeCalibrationSheet.swift
//  Mary
//
//  Tesla-calibration monitor: one bar per installed discipline, filling as
//  sealed episodes accumulate. Runtime starts the train; this sheet watches.
//

import SwiftUI
import MaryRuntime

struct LifeCalibrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = LifeCalibrationViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header
                if !viewModel.snapshot.fleetReachable {
                    Text("Fleet isn't reachable — episode fill still comes from the turn log.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                }
                if viewModel.snapshot.rows.isEmpty {
                    Text("Install a discipline Ability to begin calibration.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
                ForEach(viewModel.snapshot.rows) { row in
                    disciplineCard(row)
                }
            }
            .padding(.layer4)
        }
        .background(Paper.page)
        .frame(width: 480, height: 620)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        HStack {
            MaryMark(size: 18)
            Text("Life")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Text("\(viewModel.snapshot.readyCount) of \(viewModel.snapshot.rows.count) ready")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.5))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.mary)
        }
    }

    private func disciplineCard(_ row: LifeDisciplineStatus) -> some View {
        let expanded = viewModel.expandedID == row.id
        return MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                Button {
                    viewModel.toggleExpanded(row.id)
                } label: {
                    VStack(alignment: .leading, spacing: .layer2) {
                        HStack(spacing: .layer3) {
                            StatusDot(color: dotColor(row.phase))
                            Text(row.title)
                                .font(.marySans(13, weight: .medium))
                                .foregroundStyle(Color.maryInk)
                            Spacer()
                            Text(row.caption)
                                .font(.marySans(11))
                                .foregroundStyle(Color.maryInk.opacity(0.55))
                                .lineLimit(1)
                        }
                        CalibrationFillBar(
                            fraction: row.displayFraction,
                            pulsing: row.phase == .training)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    expandedDetail(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func expandedDetail(_ row: LifeDisciplineStatus) -> some View {
        Divider()
        if let trainedAt = row.trainedAt {
            Text(trainedAt, style: .relative)
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.4))
        } else {
            Text("Not trained yet")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.4))
        }
        if !row.modelID.isEmpty {
            Text(row.modelID)
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.45))
                .textSelection(.enabled)
        }
        if !row.artifactPath.isEmpty {
            Text(row.artifactPath)
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.35))
                .textSelection(.enabled)
        }
        if !row.cid.isEmpty {
            Text("cid \(row.cid)")
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.35))
                .textSelection(.enabled)
        }
        Text("Schema")
            .font(.marySans(11, weight: .medium))
        Text(prettyJSON(row.schemaJSON))
            .font(.maryMono(9))
            .foregroundStyle(Color.maryInk.opacity(0.75))
            .textSelection(.enabled)
        if !row.logTail.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(row.logTail.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.layer2)
            .background(Color.maryInk.opacity(0.04))
        }
    }

    private func dotColor(_ phase: LifeDisciplineStatus.Phase) -> Color {
        switch phase {
        case .collecting: return .gray
        case .training: return .maryGold
        case .ready: return .green
        }
    }

    private func prettyJSON(_ data: Data) -> String {
        guard !data.isEmpty else { return "No schema stored yet." }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8)
        {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "Unreadable schema bytes."
    }
}

/// Gold fill that grows with sealed turns. Training pulses; ready is full.
private struct CalibrationFillBar: View {
    var fraction: Double
    var pulsing: Bool
    @State private var dimmed = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.maryInk.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.maryGold)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                    .opacity(pulsing && dimmed ? 0.45 : 1)
            }
        }
        .frame(height: 6)
        .onAppear { syncPulse() }
        .onChange(of: pulsing) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        if pulsing {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        } else {
            dimmed = false
        }
    }
}
