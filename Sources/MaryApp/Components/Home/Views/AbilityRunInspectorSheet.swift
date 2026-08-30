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
    /// The turn this reply belongs to — the id a sealed `BehavioralEpisode`
    /// is filed under, so the sheet can show the whole turn beside this one
    /// Skill's calls. Nil on restored rows written before turns were stamped.
    var turnID: UUID? = nil
    var id: String { reference.id }
}

struct AbilityRunInspectorSheet: View {
    let inspected: InspectedAbilityRuns
    @Environment(\.dismiss) private var dismiss

    /// WHICH QUESTION THE SHEET IS ANSWERING.
    ///
    /// "What did this Skill do" and "what did this whole turn do" are
    /// different questions with different answers, and stacking both in one
    /// scroll made the first one — the one the tap asked — harder to find.
    private enum Lens: String, CaseIterable, Identifiable {
        case skill = "This Skill"
        case episode = "Episode"
        var id: String { rawValue }
    }

    @State private var lens: Lens = .skill
    @State private var episode: BehavioralEpisode?
    @State private var episodeLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            header
            provenance
            Picker("", selection: $lens) {
                ForEach(Lens.allCases) { lens in
                    Text(lens.rawValue).tag(lens)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch lens {
            case .skill: skillSection
            case .episode: episodeSection
            }
            Spacer(minLength: 0)
        }
        .padding(.layer4)
        .frame(minWidth: 520, minHeight: 340, maxHeight: 560)
        .background(Paper.page)
        .task(id: inspected.turnID) { await loadEpisode() }
    }

    @ViewBuilder
    private var skillSection: some View {
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
    }

    // MARK: - The episode

    /// THE WHOLE TURN, not just this Skill's part of it.
    ///
    /// A chip is the door to the sealed Ability episode in Totem: a person
    /// tapping one is already asking "what happened here", and the honest
    /// answer usually involves the calls that ran either side of the one
    /// they tapped.
    @ViewBuilder
    private var episodeSection: some View {
        if let episode {
            ScrollView {
                VStack(alignment: .leading, spacing: .layer3) {
                    episodeHeader(episode)
                    if episode.output.actions.isEmpty {
                        emptyNote("This turn recorded no actions.")
                    } else {
                        ForEach(episode.output.actions) { run in
                            runCard(run, dimmed: run.action.skill != inspected.reference)
                        }
                    }
                }
            }
        } else if !episodeLoaded {
            emptyNote("Reading the episode…")
        } else if !inspected.runs.isEmpty {
            // STILL OPEN. An episode is sealed at the END of its turn, and a
            // routine still running holds its turn's episode open — so the
            // live rows on the utterance are the only account there is yet,
            // and they are a true one.
            ScrollView {
                VStack(alignment: .leading, spacing: .layer3) {
                    emptyNote("This turn is still open — sealed when it finishes.")
                    ForEach(inspected.runs) { run in
                        runCard(run)
                    }
                }
            }
        } else {
            emptyNote(
                "This turn is not in Ability Totem. Sign in to Seer first, "
                + "or the turn had no Ability target — those are not kept.")
        }
    }

    private func episodeHeader(_ episode: BehavioralEpisode) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            if !episode.input.query.isEmpty {
                Text(episode.input.query)
                    .font(.marySerif(13, italic: true))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .textSelection(.enabled)
            }
            if let ambient = episode.input.ambient, !ambient.isEmpty {
                DisclosureGroup {
                    Text(ambient.prettyJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.65))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("Ambient capture")
                        .font(.marySans(11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
            }
            HStack(spacing: .layer2) {
                Text(episode.openedAt.formatted(date: .abbreviated, time: .standard))
                if let sealed = episode.sealedAt {
                    Text("·")
                        .foregroundStyle(Color.primary.opacity(0.3))
                    Text(String(
                        format: "%.1fs", sealed.timeIntervalSince(episode.openedAt)))
                }
                if let reason = episode.sealedReason, reason != .completed {
                    Text("·")
                        .foregroundStyle(Color.primary.opacity(0.3))
                    Text(reason.rawValue)
                        .foregroundStyle(Color.maryGold)
                }
                Text("·")
                    .foregroundStyle(Color.primary.opacity(0.3))
                Text("\(episode.output.actions.count) actions")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.5))
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.marySans(12))
            .foregroundStyle(Color.primary.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Off the main actor: Totem `documents` is a gRPC hop, and the sheet
    /// must open at once whether or not the read has landed.
    private func loadEpisode() async {
        guard let turnID = inspected.turnID else {
            episodeLoaded = true
            return
        }
        episode = await MaryRuntime.behaviorEpisode(id: turnID)
        episodeLoaded = true
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

    /// - Parameter dimmed: this row belongs to a different Skill than the chip
    ///   that was tapped. Shown, because the calls either side are most of why
    ///   someone opens the episode at all — dimmed, because they are context
    ///   for the one they asked about rather than the answer.
    private func runCard(
        _ run: BehavioralActionRecord, dimmed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Circle()
                    .fill(AbilityRunPresentation.color(run))
                    .frame(width: 8, height: 8)
                Text(AbilityRunPresentation.label(run))
                    .font(.marySans(11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                if dimmed {
                    Text(run.action.skill.invocationName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
                Spacer()
                // STOP, WHILE THERE IS STILL SOMETHING TO STOP.
                //
                // `.unsettled` is on the row from the moment the call is
                // announced, and until now it was a status word with nothing
                // behind it — a person watching a wedged call had no recourse
                // but to say "stop", which kills every routine at once. This
                // stops the one call; its lane carries on.
                if run.disposition == .unsettled {
                    Button("Stop") { RunControl.stopRun(id: run.id) }
                        .buttonStyle(.maryQuiet)
                }
                // HOW LONG IT TOOK, beside when it started. The record has
                // carried both ends since it was first written; only the
                // start was ever shown, which is the half that cannot answer
                // "why did that feel slow".
                if let duration = AbilityRunPresentation.duration(run) {
                    Text(duration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                    Text("·")
                        .foregroundStyle(Color.primary.opacity(0.3))
                }
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
        .opacity(dimmed ? 0.6 : 1)
    }

}
