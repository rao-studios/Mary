//
//  AbilityExecutionLogSheet.swift
//  Mary
//
//  The Ability execution ledger: every Skill binding, script primitive, and
//  delegate edit Mary ran this session. Undo is conversational:
//  tapping Undo sends a pre-filled chat message through the normal flow and
//  lets the model pick the right reversal (git undo, move-back, honesty).
//

import MaryBrain
import Granite
import SwiftUI
import MaryRuntime

/// Bridges the AbilityExecutionLog ring buffer to SwiftUI while open —
/// the log is a plain lock-boxed store, so a 1 s poll is the whole bridge.
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
                // WHAT IT ACTUALLY TOUCHED — the element, with its window
                // and its frame. Its predecessor showed a raw argument VALUE
                // guessed from a key called "document" or "title", which was
                // wrong whenever a package used a different word and silent
                // when the target was the thing in front of the user.
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
                            // An undo mid-turn would SUPERSEDE the user's
                            // own in-flight request — disabling beats
                            // silently discarding their turn.
                            .disabled(chat.state.isGenerating)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The conversational undo: a pre-filled message through the normal chat
    /// flow. The model picks the reversal — or says honestly that there
    /// isn't one.
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

    /// THREE STATES, because two of them were being shown as one.
    ///
    /// GREEN — did what you asked. GOLD — looked, and found nothing.
    /// RED — could not act.
    ///
    /// THE FAILURE THIS FIXES: `find_passage` on a searched-and-missed read
    /// returns `ok: true, foundNothing: true`, and that is CORRECT and stays —
    /// `ok: false` would have the turn speak the miss aloud as a breakage and
    /// invite the orchestrator to retry a read that already ran. The dot was
    /// the part that lied: a deliberate miss rendered identically to a passage
    /// found and replaced, so the one row a person opens this sheet to
    /// understand looked exactly like the rows that need no explaining.
    ///
    /// Gold is the palette's own accent (`Color.maryGold`, the border and
    /// mark colour) rather than a fourth invented amber: a miss is not a
    /// warning, it is an honest answer, and it should read as Mary's own
    /// colour rather than as a hazard.
    private static func dotColor(for record: BehavioralActionRecord) -> Color {
        switch record.disposition {
        case .succeeded: return record.foundNothing ? .maryGold : .maryGreen
        case .requestedConfirmation, .deferred, .unsettled: return .maryGold
        default: return .maryError
        }
    }

    /// The acted element as one line: what it was, in which window.
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
