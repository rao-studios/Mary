//
//  LifeCalibrationSheet.swift
//  Mary
//
//  WHAT: One bar per installed discipline as sealed episodes accumulate.
//  IN:   Runtime train. OUT: LifeCalibrationViewModel
//

import SwiftUI
import MaryBrain
import MaryRuntime

struct LifeCalibrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = LifeCalibrationViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header
                engineCard
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
        .marySheet(ideal: CGSize(width: 480, height: 620))
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

    // MARK: - The engine

    /// WHAT THE IDLE ENGINE IS DOING RIGHT NOW. Everything below this card is
    /// about earning an adapter; this card is about the thing that uses one.
    private var engineCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer3) {
                    StatusDot(color: phaseColor(viewModel.engine.phase))
                    Text("Engine")
                        .font(.marySans(13, weight: .medium))
                        .foregroundStyle(Color.maryInk)
                    Spacer()
                    Text(phaseLine)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                        .lineLimit(1)
                }

                Picker("", selection: modeBinding) {
                    ForEach(LifeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(modeExplanation)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))

                if let adapter = viewModel.engine.loadedAdapter {
                    Text("holding \(adapter.abilityID.rawValue) · gen \(adapter.generation) · \(adapter.shortCID)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }

                HStack(spacing: .layer3) {
                    Button(viewModel.pulsing ? "Pulsing…" : "Pulse now (dry run)") {
                        viewModel.pulseDryRun()
                    }
                    .buttonStyle(.mary)
                    .disabled(viewModel.pulsing || viewModel.engine.mode == .off)
                    Spacer()
                    if viewModel.engine.mode == .act {
                        Text("\(viewModel.engine.actsToday) of \(viewModel.engine.dailyActBudget) acts today")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                }

                if !viewModel.engine.recent.isEmpty {
                    Divider()
                    Text("Decisions")
                        .font(.marySans(11, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.engine.recent) { decision in
                            decisionRow(decision)
                        }
                    }
                }

                if let failure = viewModel.engine.errorTail.first {
                    Text(failure)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryError)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func decisionRow(_ decision: LifeDecision) -> some View {
        let expanded = viewModel.expandedDecisionID == decision.id
        VStack(alignment: .leading, spacing: 2) {
            Button {
                viewModel.toggleDecision(decision.id)
            } label: {
                HStack(spacing: .layer2) {
                    Text(decision.at, style: .time)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                    Text(decision.line)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.65))
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if let input = decision.input {
                    Text("Input")
                        .font(.marySans(10, weight: .medium))
                    Text(prettyEncodable(input))
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.7))
                        .textSelection(.enabled)
                }
                if let output = decision.output {
                    Text("Output")
                        .font(.marySans(10, weight: .medium))
                    Text(prettyEncodable(output))
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.7))
                        .textSelection(.enabled)
                    Text(String(
                        format: "%.0f%% of tokens forced · %d prompt tokens",
                        decision.forcedFraction * 100, decision.promptTokens))
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                }
            }
        }
    }

    private var modeBinding: Binding<LifeMode> {
        Binding(
            get: { viewModel.engine.mode },
            set: { viewModel.setMode($0) })
    }

    private var phaseLine: String {
        let phase = viewModel.engine.phase.rawValue
        let detail = viewModel.engine.phaseDetail
        return detail.isEmpty ? phase : "\(phase) · \(detail)"
    }

    private var modeExplanation: String {
        switch viewModel.engine.mode {
        case .off:
            return "Mary does nothing while you're away."
        case .observe:
            return "Mary works out what she would do and records it. She never acts."
        case .act:
            return "Mary acts on what she works out — reads and activations only. Anything that changes your work waits for you."
        }
    }

    private func phaseColor(_ phase: LifeEnginePhase) -> Color {
        switch phase {
        case .off, .paused: return .gray
        case .idle, .waiting, .cooldown: return Color.maryInk.opacity(0.4)
        case .inferring, .acting: return .maryGold
        case .failed: return .maryError
        }
    }

    private func prettyEncodable<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "—" }
        return text
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
        if row.ready {
            Toggle(
                "Let this answer live turns",
                isOn: Binding(
                    get: { viewModel.answersTurns(row.id) },
                    set: { viewModel.setAnswersTurns(row.id, $0) }))
                .font(.marySans(11))
            Text("Off by default. When on, Mary answers turns in this discipline through the trained adapter instead of reasoning them out — faster and more like you, but only as good as what it learned.")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        }
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
