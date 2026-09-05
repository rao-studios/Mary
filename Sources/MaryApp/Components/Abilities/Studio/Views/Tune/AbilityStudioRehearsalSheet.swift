//
//  AbilityStudioRehearsalSheet.swift
//  Mary
//
//  WHAT: Say it, and watch the real routing path decide.
//  IN:   Tune pane.
//  OUT:  AbilityStudioRoutingRehearsal; "Keep as fixture" → addFixture.
//  PIN:  Anything inside the margin band IS the conflict — that band is what
//        suppresses the no-model shortcut. And the lever is a fixture, because
//        phrases never reach the skill tier.
//

import Granite
import MaryBrain
import MaryRuntime
import SwiftUI

@MainActor
struct AbilityStudioRehearsalSheet: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @Environment(\.dismiss) private var dismiss
    @Relay(.silence) var voice: VoiceService

    @State private var typed = ""
    @State private var rehearsal: AbilityStudioRehearsal?
    @State private var keptFixture = false
    /// WHAT IS IN FRONT WHILE THEY SAY IT. The roster is arbitrated against the
    /// lead application's target classes, so the same sentence reaches different
    /// skills depending on the window — which is the whole of the "pause the
    /// music while a browser is fronted" failure, and was invisible here.
    @State private var stageID: String?

    /// While a voice session is live the partial transcript is the utterance —
    /// observation only. Mary has no listen-without-dispatch mode.
    private var utterance: String {
        let partial = voice.state.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        return voice.state.isSessionActive && !partial.isEmpty ? partial : typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer4) {
            header
            utteranceBar
            ScrollView {
                if let rehearsal {
                    VStack(alignment: .leading, spacing: .layer4) {
                        verdictBanner(rehearsal)
                        HStack(alignment: .top, spacing: .layer4) {
                            tiers(rehearsal)
                            levers(rehearsal)
                                .maryColumn(Paper.Layout.drawer)
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        VStack(spacing: .layer3) {
                            MaryEmblem(iconSize: 44)
                            Text("Say it and see")
                                .font(.marySerif(16, weight: .light, italic: true))
                                .foregroundStyle(Color.maryInk)
                            Text("This runs the same indexes the turn loop runs, against the registry that is active right now.")
                                .font(.marySans(11))
                                .foregroundStyle(Color.maryInk.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                        Spacer()
                    }
                    .padding(.vertical, .layer6)
                }
            }
            .scrollIndicators(.never)
            footer
        }
        .padding(.layer5)
        // Floor is the width below which the two columns stop fitting their
        // own minimums: a candidate row is 340 wide, +32 card padding, +260
        // for the levers column, +64 gutter and sheet padding.
        .marySheet(
            ideal: CGSize(width: 900, height: 640),
            floor: CGSize(width: 720, height: 440))
        .background(Color.maryBG)
        .preferredColorScheme(.light)
        #if DEBUG
        // Harness only, inert without MARY_LAYOUT_CHECK — see MaryLayoutCheck.
        .onAppear {
            guard let seeded = MaryLayoutCheck.utterance, typed.isEmpty else { return }
            typed = seeded
            run()
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            MaryMark(size: 18)
            Text("Routing rehearsal")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            if let rehearsal {
                Text("registry \(rehearsal.revision)")
                    .font(.maryMono(9.5))
                    .foregroundStyle(Color.maryInk.opacity(0.35))
            }
        }
    }

    // MARK: - Utterance

    private var utteranceBar: some View {
        MaryCard(padding: .layer4) {
            HStack(spacing: .layer3) {
                Circle()
                    .fill(voice.state.isSessionActive ? Color.maryGold : Color.maryFill)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(voice.state.isSessionActive
                                             ? Color.white
                                             : Color.maryInk.opacity(0.4)))
                    .help(voice.state.isSessionActive
                          ? "Listening — what Mary hears is rehearsed as you speak."
                          : "Start a voice session in the main window to rehearse by speaking.")

                if voice.state.isSessionActive, !voice.state.lastPartial.isEmpty {
                    Text(voice.state.lastPartial)
                        .font(.marySerif(15, italic: true))
                        .foregroundStyle(Color.maryInk.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("something someone would say…", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.marySerif(15, italic: true))
                        .foregroundStyle(Color.maryInk)
                        .onSubmit(run)
                }

                Picker("", selection: $stageID) {
                    Text("nothing in front").tag(String?.none)
                    ForEach(stages) { stage in
                        Text("as if \(stage.title) were in front").tag(String?.some(stage.id))
                    }
                }
                .labelsHidden()
                .font(.marySans(10))
                .frame(width: Paper.Layout.stagePicker)
                .help(AbilityRosterRehearsal.caveat)

                Button("Rehearse", action: run)
                    .buttonStyle(.mary)
                    .disabled(utterance.isEmpty)
                    .opacity(utterance.isEmpty ? 0.4 : 1)
                    .fixedSize()
            }
        }
    }

    private func verdictBanner(_ rehearsal: AbilityStudioRehearsal) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            Image(systemName: rehearsal.isClean ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(rehearsal.isClean ? Color.maryGreen : Color.maryError)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: .layer1) {
                Text(rehearsal.verdictWord)
                    .font(.marySans(11.5))
                    .foregroundStyle(Color.maryInk.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                // THE ROSTER'S OWN DISAGREEMENT, when it has one. The tiers can
                // say a skill leads and the turn still not have it.
                if let roster = rehearsal.rosterWord {
                    Text(roster)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryError.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.layer3)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((rehearsal.isClean ? Color.maryGreen : Color.maryError).opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    (rehearsal.isClean ? Color.maryGreen : Color.maryError).opacity(0.3),
                    lineWidth: 1))
    }

    // MARK: - Tiers

    private func tiers(_ rehearsal: AbilityStudioRehearsal) -> some View {
        MaryCard(padding: .layer4) {
            VStack(alignment: .leading, spacing: .layer3) {
                tier(
                    "Skill tier",
                    caption: "title, summary, invocation, id, eligibility phrases, route fixtures",
                    rows: rehearsal.skills)
                Divider().overlay(Color.maryBorder)
                tier(
                    "Ability tier",
                    caption: "tokens, phrases, aliases, habits, fixtures — minus negatives",
                    rows: rehearsal.abilities)
                if let expertise = rehearsal.expertise {
                    Divider().overlay(Color.maryBorder)
                    expertiseTier(expertise, reading: rehearsal.expertiseWord)
                }
                legend
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tier(
        _ title: String,
        caption: String,
        rows: [AbilityStudioRehearsal.Candidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(alignment: .firstTextBaseline, spacing: .layer2) {
                SectionLabel(title)
                Text(caption)
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                    .lineLimit(1)
            }
            if rows.isEmpty {
                Text("Nothing scored.")
                    .font(.marySans(10.5))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            ForEach(rows.prefix(6)) { row in
                candidateRow(row, winner: rows.first)
            }
        }
    }

    /// WHO INHERITS THE WINNING DISCIPLINE. A skill like `control_playback`
    /// belongs to `multimedia`, which is nobody's application — the packages
    /// that REQUIRE multimedia are the players it can land in, and the ranking
    /// among them is this person's own decayed history.
    private func expertiseTier(
        _ verdict: ExpertiseResolution.Verdict,
        reading: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(alignment: .firstTextBaseline, spacing: .layer2) {
                SectionLabel("Expertise tier")
                Text("who inherits \(verdict.disciplineID.rawValue) — ranked by what you reach for")
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                    .lineLimit(1)
            }
            if verdict.candidates.isEmpty {
                Text("Nothing extends this ability — the turn stays with the discipline's own binding.")
                    .font(.marySans(10.5))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            ForEach(verdict.candidates.prefix(6)) { row in
                expertiseRow(row, chosen: verdict.chosen?.expertiseID == row.expertiseID)
            }
            if let reading {
                StudioNote(reading)
            }
        }
    }

    private func expertiseRow(
        _ row: ExpertiseResolution.Candidate,
        chosen: Bool
    ) -> some View {
        HStack(spacing: .layer2) {
            Circle()
                .fill(Color.maryAbilityTint(row.tint))
                .frame(width: 6, height: 6)
            Text(row.applicationID)
                .font(.maryMono(10))
                .foregroundStyle(Color.maryInk.opacity(chosen ? 0.85 : 0.5))
                .lineLimit(1)
                .frame(width: Paper.Layout.labelColumn, alignment: .leading)

            // SHARE, NOT AFFINITY. These are summed recency weights on their
            // own scale, so they get their own bar rather than borrowing the
            // 0.30–0.80 axis the two scored tiers share.
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.maryInk.opacity(0.06))
                        .frame(width: width, height: 6)
                    Rectangle()
                        .fill(Self.expertiseColor(row.standing))
                        .frame(width: max(1, CGFloat(row.share) * width), height: 6)
                }
                .frame(height: 18)
            }
            .frame(height: 18)

            Text(String(format: "%.2f", row.weight))
                .font(.maryMono(10))
                .foregroundStyle(Self.expertiseColor(row.standing))
                .frame(width: 34, alignment: .trailing)
            Text(Self.expertiseWord(row.standing))
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.4))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private static func expertiseColor(
        _ standing: ExpertiseResolution.Standing
    ) -> Color {
        switch standing {
        case .asserted: return .maryGold
        case .habitual: return .maryGreen
        case .fallback: return Paper.graphite
        case .staticPreference: return Paper.graphite
        }
    }

    private static func expertiseWord(
        _ standing: ExpertiseResolution.Standing
    ) -> String {
        switch standing {
        case .asserted: return "you said"
        case .habitual: return "habit"
        case .fallback: return "less used"
        case .staticPreference: return "default"
        }
    }

    /// One tick on a 0.30–0.80 scale, with the floor drawn as a line and the
    /// winner's margin as a band. Inside that band is what blocks the shortcut.
    private func candidateRow(
        _ row: AbilityStudioRehearsal.Candidate,
        winner: AbilityStudioRehearsal.Candidate?
    ) -> some View {
        HStack(spacing: .layer2) {
            Circle()
                .fill(Color.maryAbilityTint(row.ownerTint))
                .frame(width: 6, height: 6)
            Text(row.invocation ?? row.id)
                .font(.maryMono(10))
                .foregroundStyle(Color.maryInk.opacity(row.standing == .belowFloor ? 0.4 : 0.85))
                .lineLimit(1)
                .frame(width: Paper.Layout.labelColumn, alignment: .leading)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    if let winner, winner.affinity >= AbilityStudioRehearsal.floor {
                        Rectangle()
                            .fill(Color.maryError.opacity(0.10))
                            .frame(
                                width: max(1, Self.span(AbilityStudioRehearsal.margin) * width),
                                height: 18)
                            .offset(x: Self.x(winner.affinity - AbilityStudioRehearsal.margin) * width)
                    }
                    Rectangle()
                        .fill(Color.maryGold.opacity(0.7))
                        .frame(width: 1, height: 18)
                        .offset(x: Self.x(AbilityStudioRehearsal.floor) * width)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(row.color)
                        .frame(width: 3, height: 13)
                        .offset(x: Self.x(row.affinity) * width - 1.5)
                }
                .frame(height: 18)
            }
            .frame(height: 18)

            Text(String(format: "%.2f", row.affinity))
                .font(.maryMono(10))
                .foregroundStyle(row.color)
                .frame(width: 34, alignment: .trailing)
            Text(row.standing == .winner
                 ? "winner"
                 : row.standing == .belowFloor
                    ? "below floor"
                    : "−\(String(format: "%.2f", row.deltaToWinner))")
                .font(.maryMono(9))
                .foregroundStyle(row.standing == .crowding
                                 ? Color.maryError
                                 : Color.maryInk.opacity(0.4))
                .frame(width: 58, alignment: .trailing)

            // WAS IT OFFERED AT ALL — the question the tiers beside it cannot
            // answer. A skill can lead its corpus outright and still never
            // reach the model.
            if let disposition = row.disposition {
                Text(row.wasOffered ? "offered" : disposition.rawValue)
                    .font(.maryMono(9))
                    .foregroundStyle(row.wasOffered
                                     ? Color.maryGreen
                                     : Color.maryError.opacity(0.75))
                    .frame(width: 96, alignment: .trailing)
                    .help(row.rosterReason ?? "")
            }
        }
    }

    private static let low: Float = 0.30
    private static let high: Float = 0.80

    static func x(_ value: Float) -> CGFloat {
        CGFloat(min(max((value - low) / (high - low), 0), 1))
    }

    static func span(_ value: Float) -> CGFloat {
        CGFloat(min(max(value / (high - low), 0), 1))
    }

    private var legend: some View {
        HStack(spacing: .layer4) {
            HStack(spacing: 5) {
                Rectangle().fill(Color.maryGold.opacity(0.7)).frame(width: 1, height: 9)
                Text("floor \(String(format: "%.2f", AbilityStudioRehearsal.floor))")
            }
            HStack(spacing: 5) {
                Rectangle().fill(Color.maryError.opacity(0.14)).frame(width: 13, height: 9)
                Text("margin \(String(format: "%.2f", AbilityStudioRehearsal.margin)) — anything in here blocks the shortcut")
            }
            HStack(spacing: 5) {
                Rectangle().fill(Color.maryGreen).frame(width: 13, height: 6)
                Text("habit weight halves every 30 days — switch players and the ranking follows")
            }
            Spacer(minLength: 0)
        }
        .font(.marySans(9))
        .foregroundStyle(Color.maryInk.opacity(0.45))
    }

    // MARK: - Levers

    private func levers(_ rehearsal: AbilityStudioRehearsal) -> some View {
        VStack(alignment: .leading, spacing: .layer3) {
            if let crowder = rehearsal.crowder {
                MaryCard(padding: .layer4) {
                    VStack(alignment: .leading, spacing: .layer2) {
                        SectionLabel("What the crowder is")
                        HStack(spacing: .layer2) {
                            Circle()
                                .fill(Color.maryAbilityTint(crowder.ownerTint))
                                .frame(width: 7, height: 7)
                            Text(crowder.invocation ?? crowder.id)
                                .font(.maryMono(10.5))
                                .foregroundStyle(Color.maryInk)
                            StudioOwnerChip(
                                title: crowder.ownerTitle,
                                tint: Color.maryAbilityTint(crowder.ownerTint))
                        }
                        if let group = crowder.conflictGroup {
                            AbilityStudioFactLine(label: "Group", value: group)
                        }
                        if let policy = crowder.conflictPolicy {
                            AbilityStudioFactLine(label: "Policy", value: policy.rawValue)
                        }
                        if let preference = crowder.preference {
                            AbilityStudioFactLine(
                                label: "Order",
                                value: "\(preference) · a sort key, not a weight")
                        }
                        StudioNote("If the shortcut is blocked the arbitrator decides, and it ranks on evidence — direct interaction first under this policy, then total evidence. Order never enters that ranking.")
                    }
                }
            }

            MaryCard(padding: .layer4) {
                VStack(alignment: .leading, spacing: .layer3) {
                    SectionLabel("Pull them apart")
                    lever(
                        "checkmark",
                        "Keep this as a fixture.",
                        "Writes the sentence into this ability's fixtures. It is the one lever that moves the skill tier — a whole authored sentence joins that skill's corpus.")
                    lever(
                        "xmark",
                        "Push the other one down.",
                        "A negative token subtracts from the ability tier. Sharpening the crowder's own summary and eligibility phrases is what moves the skill tier.")
                    lever(
                        "hand.tap",
                        "Teach the player by using it.",
                        "There is no knob for the expertise tier. Every successful act in a player is a vote, and votes halve every thirty days — a new player overtakes the old one on its own, and going back reverses it just as quietly.")
                    lever(
                        "exclamationmark.triangle",
                        "Phrases do not reach here.",
                        "An ability's phrases feed the ability tier only. Tuning them cannot separate two skills inside the same ability — fixtures can.")

                    Divider().overlay(Color.maryBorder)

                    HStack(spacing: .layer2) {
                        StudioNote("Indexes rebuild on registry reload, so a new fixture changes routing after Save.")
                        Spacer()
                        Button(keptFixture ? "Kept" : "Keep as fixture", action: keep)
                            .buttonStyle(.mary)
                            .disabled(keptFixture || rehearsal.utterance.isEmpty)
                            .opacity(keptFixture || rehearsal.utterance.isEmpty ? 0.4 : 1)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func lever(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(Color.maryGold)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.marySans(10.5, weight: .medium))
                    .foregroundStyle(Color.maryInk.opacity(0.8))
                StudioNote(text)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: .layer2) {
            StudioNote("Runs the same indexes the turn loop runs. Nothing here dispatches anything.")
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.maryQuiet)
        }
    }

    // MARK: - Actions

    private func run() {
        keptFixture = false
        rehearsal = AbilityStudioRehearsal.run(
            utterance: utterance,
            snapshot: model.snapshot,
            stage: stages.first { $0.id == stageID })
    }

    /// Every installed application, as a stage to rehearse in front of.
    private var stages: [AbilityStudioRehearsal.Stage] {
        model.snapshot.plugins.applicationProfiles
            .filter { !$0.targetClasses.isEmpty }
            .map {
                AbilityStudioRehearsal.Stage(
                    id: $0.id, title: $0.title, targetClasses: $0.targetClasses)
            }
            .sorted { $0.title < $1.title }
    }

    /// The winner is what this sentence should reach, so that is what the
    /// fixture names — falling back to the selected recipe.
    private func keep() {
        guard let rehearsal else { return }
        let expected = rehearsal.skills.first { $0.standing == .winner }
            .flatMap { candidate -> SkillID? in
                let id = SkillID(candidate.id)
                return package.skills.contains { $0.id == id } ? id : nil
            }
        let accepted = model.mutateAuthoringDocument { document in
            try document.addFixture(
                utterance: rehearsal.utterance,
                expectedSkill: expected ?? model.selectedRecipe?.id,
                // WHAT WAS IN FRONT WHEN THEY SAID IT. A fixture with no target
                // class is a claim about no particular surface, which a
                // target-class-gated ability can never be tested against.
                targetClass: rehearsal.stage?.targetClasses.sorted().first)
        }
        keptFixture = accepted
    }
}
