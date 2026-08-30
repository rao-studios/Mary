//
//  AbilityExecutionLogSheet.swift
//  Mary
//
//  WHAT: Session Ability ledger (bindings, primitives, delegate edits).
//  OUT:  Undo → TextTurnRunner (pre-filled chat). Polls AbilityExecutionLog.
//

import MaryBrain
import Granite
import SwiftUI
import MaryRuntime

/// Bridges AbilityExecutionLog (lock-boxed) to SwiftUI via a 1 s poll while open.
@MainActor
final class AbilityExecutionLogViewModel: ObservableObject {

    @Published var records: [BehavioralActionRecord] = []

    private var pollTask: Task<Void, Never>?

    func start() {
        records = AbilityExecutionLog.shared.entries()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.records = AbilityExecutionLog.shared.entries()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func clear() {
        AbilityExecutionLog.shared.clear()
        records = []
    }
}

struct AbilityExecutionLogSheet: View {
    @Relay var chat: ChatService
    @Relay var config: ConfigService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = AbilityExecutionLogViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header
                timeoutCard
                if viewModel.records.isEmpty {
                    emptyCard
                } else {
                    ForEach(viewModel.records) { record in
                        recordCard(record)
                    }
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
            Text("Ability runs")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            Button("Clear") { viewModel.clear() }
                .buttonStyle(.maryQuiet)
                .disabled(viewModel.records.isEmpty)
            Button("Done") { dismiss() }
                .buttonStyle(.mary)
        }
    }

    private var timeoutCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("still working")
                HStack(spacing: .layer3) {
                    Slider(value: timeoutBinding, in: 1...10, step: 1)
                    Text("\(Int(config.state.skillRunTimeoutSeconds.rounded()))s")
                        .font(.maryMono(10))
                        .frame(width: 28, alignment: .trailing)
                }
                Text("Ordinary Skills stop after this many seconds so they cannot stack. Builds and tests keep their own longer ceilings.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { config.state.skillRunTimeoutSeconds },
            set: { seconds in
                let clamped = AbilityRuntime.clampedOrdinarySkillTimeout(seconds)
                config.center.update.send(
                    ConfigService.Update.Meta(skillRunTimeoutSeconds: clamped))
                MaryRuntime.applySkillRunTimeout(clamped)
            }
        )
    }

    private var emptyCard: some View {
        MaryCard {
            Text("No Ability Skill has run yet this session. Each execution lands here with its package, target, and result.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    private func recordCard(_ record: BehavioralActionRecord) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                HStack(spacing: .layer3) {
                    StatusDot(color: Self.dotColor(for: record))
                    HStack(spacing: 4) {
                        Text(record.action.skill.abilityID.rawValue)
                            .foregroundStyle(
                                Color.maryAbilityTint(record.action.skill.abilityTint))
                        Text("|").foregroundStyle(Color.maryInk.opacity(0.3))
                        Text(record.action.intention)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(record.action.skill.packageID.rawValue)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                    Spacer()
                    Text(Self.timeFormatter.string(from: record.startedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                // Element + window + frame (not a guessed argument value).
                if let target = record.action.target {
                    Text(Self.targetLine(target))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.maryInk.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !record.action.adapters.isEmpty {
                    Text("via " + record.action.adapters.map(\.rawValue).joined(separator: " → "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                Text(record.summary)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                    .lineLimit(2)
                if record.undoable && record.disposition == .succeeded {
                    HStack {
                        Button("Undo") { undo(record) }
                            .buttonStyle(.maryQuiet)
                            // Mid-turn undo would supersede the in-flight request.
                            .disabled(chat.state.isGenerating)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Conversational undo: pre-filled message through normal chat. Model picks the reversal.
    private func undo(_ record: BehavioralActionRecord) {
        let subject = record.action.target.map(Self.targetLine)
            ?? record.action.skill.packageID.rawValue
        let message = "Please reverse this Ability run from my log: \(record.action.intention) on \(subject) — the result was: \(record.summary)"
        let center = chat.center
        Task {
            await TextTurnRunner.shared.submit(message) { kind in
                center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: kind))
            }
        }
        dismiss()
    }

    // MARK: - Display helpers

    /// Green = did it. Gold = looked and found nothing (or still working). Red = could not act.
    /// PIN: `foundNothing` stays `ok`; the dot used to look like success.
    private static func dotColor(for record: BehavioralActionRecord) -> Color {
        switch record.disposition {
        case .succeeded: return record.foundNothing ? .maryGold : .maryGreen
        case .requestedConfirmation, .deferred, .unsettled: return .maryGold
        default: return .maryError
        }
    }

    /// Acted element as one line: label, then window.
    private static func targetLine(_ target: AXElementRecord) -> String {
        let label = target.label.isEmpty ? target.role : target.label
        return target.windowTitle.isEmpty ? label : "\(label) — \(target.windowTitle)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
