//
//  AbilityRunInspectorSheet.swift
//  Mary
//
//  WHAT: Skill-call silo (args, receipt, status). Chat body stays prose-only.
//  IN:   AbilityBadgeRow tap
//  OUT:  BehavioralEpisode (turn) beside this Skill's calls
//

import MaryBrain
import SwiftUI
import MaryRuntime

/// Tapped chip identity + runs on that utterance. `Identifiable` for `.sheet(item:)`.
struct InspectedAbilityRuns: Identifiable {
    /// Nil = the "looked first" capsule was tapped — Mary's own reads for
    /// the whole turn, not scoped to one Skill. No "This Skill"/"Episode"
    /// lens split then; `runs` is already the turn's whole own-read set.
    let reference: AbilitySkillReference?
    let runs: [BehavioralActionRecord]
    /// Turn this reply belongs to (sealed episode id). Nil on restored rows from before stamps.
    var turnID: UUID? = nil
    var id: String { reference?.id ?? "own-reads-\(turnID?.uuidString ?? "standalone")" }

    init(reference: AbilitySkillReference, runs: [BehavioralActionRecord], turnID: UUID? = nil) {
        self.reference = reference
        self.runs = runs
        self.turnID = turnID
    }

    /// Mary's own reads for the turn — the capsule's tap target.
    init(ownReads runs: [BehavioralActionRecord], turnID: UUID?) {
        self.reference = nil
        self.runs = runs
        self.turnID = turnID
    }
}

struct AbilityRunInspectorSheet: View {
    let inspected: InspectedAbilityRuns
    @Environment(\.dismiss) private var dismiss

    /// Skill vs whole-turn. Separate lenses; the tap asked for the Skill first.
    private enum Lens: String, CaseIterable, Identifiable {
        case skill = "This Skill"
        case episode = "Episode"
        var id: String { rawValue }
    }

    @State private var lens: Lens = .skill
    @State private var episode: BehavioralEpisode?
    @State private var episodeLoaded = false

    /// The capsule's tap, not a chip's — one Skill to scope down from, so no lens.
    private var isOwnReadsOnly: Bool { inspected.reference == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            header
            provenance
            if isOwnReadsOnly {
                ownReadsSection
            } else {
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

    /// Every Ability this turn read from before answering — unlike
    /// `skillSection`, more than one Skill can appear, so each card names its own.
    @ViewBuilder
    private var ownReadsSection: some View {
        if inspected.runs.isEmpty {
            Text("No pre-reads recorded for this turn.")
                .font(.marySans(12))
                .foregroundStyle(Color.primary.opacity(0.6))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: .layer3) {
                    ForEach(inspected.runs) { run in
                        runCard(run, showsSkillName: true)
                    }
                }
            }
        }
    }

    // MARK: - The episode

    /// Whole turn, not just this Skill. Chip opens the sealed episode.
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
                            runCard(run, dimmed: inspected.reference.map { run.action.skill != $0 } ?? false)
                        }
                    }
                }
            }
        } else if !episodeLoaded {
            emptyNote("Reading the episode…")
        } else if !inspected.runs.isEmpty {
            // Episode seals at turn end; live utterance rows are the account while open.
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

    /// Off MainActor: Totem `documents` is a gRPC hop; sheet must open immediately.
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
            if let reference = inspected.reference {
                Text(reference.abilityTitle)
                    .font(.marySans(14, weight: .semibold))
                    .foregroundStyle(Color.maryAbilityTint(reference.abilityTint))
                Text("|")
                    .foregroundStyle(Color.primary.opacity(0.32))
                Text(reference.invocationName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))
            } else {
                Text("Looked first")
                    .font(.marySans(14, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Which plugin ran (compiled vs package-taught). Chip has no room for
    /// this — and own-reads mode can span more than one, so each card names
    /// its own Skill instead of one header line claiming a single provider.
    @ViewBuilder
    private var provenance: some View {
        if let provider = inspected.reference?.provider {
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

    /// - Parameter dimmed: other Skill on the same turn — shown as context, not the answer.
    /// - Parameter showsSkillName: names the calling Skill regardless of
    ///   `dimmed` — own-reads mode can span several Skills with none of them
    ///   dimmed, so which one made this call is not otherwise visible.
    private func runCard(
        _ run: BehavioralActionRecord, dimmed: Bool = false, showsSkillName: Bool? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Circle()
                    .fill(AbilityRunPresentation.color(run))
                    .frame(width: 8, height: 8)
                Text(AbilityRunPresentation.label(run))
                    .font(.marySans(11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                if showsSkillName ?? dimmed {
                    Text(run.action.skill.invocationName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
                Spacer()
                // Stop this call only; the lane continues.
                if run.disposition == .unsettled {
                    Button("Stop") { RunControl.stopRun(id: run.id) }
                        .buttonStyle(.maryQuiet)
                }
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
            // Target + adapters: where the call landed.
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
