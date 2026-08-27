//
//  AbilityRunInspectorSheet.swift
//  Mary
//
//  THE SILO the machine summaries moved into. "Sketch completed the
//  document-model command…" used to stack up as chat paragraphs; the chat
//  body is prose-only now, and everything a skill call actually did — its
//  arguments, its receipt summary, its status — lives here, one tap away on
//  the chip that named it. `ContributionInspectorSheet` is the presentation
//  precedent (tap an inline element → a sheet).
//

import MaryBrain
import SwiftUI
import MaryRuntime

/// The tapped chip's identity plus the runs it made on that utterance —
/// `Identifiable` so `.sheet(item:)` drives presentation.
struct InspectedAbilityRuns: Identifiable {
    let reference: AbilitySkillReference
    let runs: [BehavioralActionRecord]
    var id: String { reference.id }
}

struct AbilityRunInspectorSheet: View {
    let inspected: InspectedAbilityRuns
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            header
            provenance
            if inspected.runs.isEmpty {
                Text("No recorded calls for this Skill on this reply.")
                    .font(.marySans(12))
                    .foregroundStyle(Color.primary.opacity(0.6))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: .layer3) {
                        ForEach(inspected.runs) { run in
                            runCard(run)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.layer4)
        .frame(minWidth: 440, minHeight: 280, maxHeight: 480)
        .background(Paper.page)
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            Text(inspected.reference.abilityTitle)
                .font(.marySans(14, weight: .semibold))
                .foregroundStyle(Color.maryAbilityTint(inspected.reference.abilityTint))
            Text("|")
                .foregroundStyle(Color.primary.opacity(0.32))
            Text(inspected.reference.invocationName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// WHO ACTUALLY DID IT. The sheet has room the chip does not, and the
    /// receipt has carried this all along without anything showing it: which
    /// plugin ran, and whether it was compiled into Mary or taught by an
    /// Ability package.
    @ViewBuilder
    private var provenance: some View {
        if let provider = inspected.reference.provider {
            let realization = AbilityRealizationPresentation(provider.pluginClass)
            HStack(spacing: .layer2) {
                Image(systemName: realization.symbol)
                Text("via \(provider.pluginTitle)")
                Text("·")
                    .foregroundStyle(Color.primary.opacity(0.32))
                Text(realization.label)
            }
            .font(.marySans(11))
            .foregroundStyle(Color.primary.opacity(0.6))
            .help(realization.help)
        }
    }

    private func runCard(_ run: BehavioralActionRecord) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Circle()
                    .fill(statusColor(run))
                    .frame(width: 8, height: 8)
                Text(statusLabel(run))
                    .font(.marySans(11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                Spacer()
                Text(run.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
            }
            if !run.action.argumentsJSON.isEmpty, run.action.argumentsJSON != "{}" {
                Text(run.action.argumentsJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(.marySans(12))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .textSelection(.enabled)
            }
            // WHAT IT TOUCHED, and through which adapters. The inspector is
            // where a person goes to ask "but WHERE did that land", and until
            // the record carried a target there was no answer to give.
            if let target = run.action.target {
                Text("\(target.label.isEmpty ? target.role : target.label) — \(target.windowTitle)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .textSelection(.enabled)
            }
            if !run.action.adapters.isEmpty {
                Text("via " + run.action.adapters.map(\.rawValue).joined(separator: " → "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
            }
        }
        .padding(.layer3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func statusColor(_ run: BehavioralActionRecord) -> Color {
        switch run.disposition {
        case .succeeded: return run.foundNothing ? .maryGold : .maryGreen
        case .unsettled: return Color.primary.opacity(0.3)
        case .requestedConfirmation, .deferred: return .maryGold
        default: return .maryError
        }
    }

    private func statusLabel(_ run: BehavioralActionRecord) -> String {
        switch run.disposition {
        case .succeeded: return run.foundNothing ? "looked, found nothing" : "completed"
        case .failed: return "did not go through"
        case .blocked: return "refused"
        case .cancelled: return "stopped"
        case .deferred: return "handed off"
        case .requestedConfirmation: return "waiting on you"
        case .unsettled: return "running"
        case .unknown: return "unknown"
        }
    }
}
