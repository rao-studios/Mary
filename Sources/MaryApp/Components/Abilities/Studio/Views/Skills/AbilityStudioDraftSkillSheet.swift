//
//  AbilityStudioDraftSkillSheet.swift
//  Mary
//
//  WHAT: Say what an ability should do; Seer drafts the blocks; you confirm them.
//  IN:   Skills pane.
//  OUT:  mutateAuthoringDocument { addRemoteHandsAction } — the same gate a
//        hand-built action goes through.
//  PIN:  Nothing here is written from the model's answer directly. The validator
//        still has the last word, and blocks it guessed at are flagged for a
//        live run before they are kept.
//

import MaryBrain
import MaryRuntime
import SwiftUI

@MainActor
struct AbilityStudioDraftSkillSheet: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @Environment(\.dismiss) private var dismiss

    @State private var goal = ""
    @State private var capture: AbilityStudioSurfaceCapture.Outcome?
    @State private var selectedFrames: Set<String> = []
    @State private var outcome: AbilityStudioDraftOutcome?
    @State private var failure: String?
    @State private var isDrafting = false
    @State private var seerIsReady: Bool?

    private var drafter: AbilityStudioSkillDrafter {
        AbilityStudioSkillDrafter(complete: MaryRuntime.studioComplete)
    }

    private var applicationTitle: String {
        package.plugin?.application.title ?? package.ability.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer4) {
            header
            HStack(alignment: .top, spacing: .layer4) {
                VStack(alignment: .leading, spacing: .layer4) {
                    goalStep
                    surfaceStep
                }
                .frame(width: 330)

                proposalStep
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.layer5)
        .frame(width: 860, height: 620)
        .background(Color.maryBG)
        .preferredColorScheme(.light)
        .onAppear { capture = AbilityStudioSurfaceCapture.read(package: package) }
        .task { seerIsReady = await drafter.isReady() }
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            MaryMark(size: 18)
            Text("Draft a skill")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            StudioNote("Mary can teach an application new hands. It cannot invent a faculty.")
                .frame(maxWidth: 300)
        }
    }

    // MARK: - 1. Goal

    private var goalStep: some View {
        MaryCard(padding: .layer4) {
            VStack(alignment: .leading, spacing: .layer3) {
                stepTitle(1, "What should it do?")
                StudioTextArea(
                    value: goal,
                    minHeight: 46,
                    live: true
                ) { goal = $0 }
                StudioNote("Say it the way you would ask for it.")
            }
        }
    }

    // MARK: - 2. Surface

    private var surfaceStep: some View {
        MaryCard(padding: .layer4) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer2) {
                    stepTitle(2, "Where does it happen?")
                    Spacer()
                    Button("Read again") {
                        capture = AbilityStudioSurfaceCapture.read(package: package)
                        selectedFrames = []
                    }
                    .buttonStyle(.plain)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryGold)
                }

                if let reason = capture?.reason {
                    HStack(alignment: .top, spacing: .layer2) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.maryGold)
                        Text(reason)
                            .font(.marySans(10.5))
                            .foregroundStyle(Color.maryInk.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    StudioNote("A live read of \(applicationTitle). Tick the frames the action has to reach — these are the only anchors Seer may name.")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(capture?.frames ?? []) { frame in
                                frameRow(frame)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: 190)
                    Text("\(selectedFrames.count) of \(capture?.frames.count ?? 0) selected")
                        .font(.marySans(9.5))
                        .foregroundStyle(Color.maryInk.opacity(0.42))
                }
            }
        }
    }

    private func frameRow(_ frame: AbilityStudioSurfaceFrame) -> some View {
        let isOn = selectedFrames.contains(frame.id)
        return Button {
            if isOn { selectedFrames.remove(frame.id) } else { selectedFrames.insert(frame.id) }
        } label: {
            HStack(spacing: .layer2) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.maryGold : Color.clear)
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.maryGold.opacity(isOn ? 1 : 0.45), lineWidth: 1))
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isOn ? 1 : 0))
                Text(frame.role)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryGold)
                Text(frame.label)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: .layer1)
                if !frame.trail.isEmpty {
                    Text(frame.trail.suffix(2).joined(separator: " ▸ "))
                        .font(.maryMono(8))
                        .foregroundStyle(Color.maryInk.opacity(0.3))
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Paper.highlight.opacity(0.22) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. Proposal

    @ViewBuilder
    private var proposalStep: some View {
        MaryCard(padding: .layer4) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer2) {
                    stepTitle(3, "Seer's proposal")
                    Spacer()
                    if case .drafted = outcome {
                        MaryBadge(text: "draft", color: .maryGold)
                    }
                }

                switch outcome {
                case .drafted(let action):
                    drafted(action)
                case .needsFaculty(let reason):
                    refusal(reason)
                case nil:
                    if let failure {
                        Text(failure)
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryError)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if seerIsReady == false {
                        HStack(alignment: .top, spacing: .layer2) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.maryGold)
                            Text("Seer is not signed in, so nothing can be drafted right now. Check the Servers panel.")
                                .font(.marySans(10.5))
                                .foregroundStyle(Color.maryInk.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        StudioNote(isDrafting
                                   ? "Reading the window and writing the blocks…"
                                   : "Nothing yet. Say what it should do, tick the frames it touches, then draft it.")
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private func drafted(_ action: AbilityStudioDraftedAction) -> some View {
        VStack(alignment: .leading, spacing: .layer3) {
            Text(action.title)
                .font(.marySerif(14, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Text(action.summary)
                .font(.marySans(10.5))
                .foregroundStyle(Color.maryInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            if !action.inputs.isEmpty {
                FlowLayout(spacing: .layer1) {
                    ForEach(action.inputs) { input in
                        Text("\(input.name) · \(input.kind.rawValue)\(input.required ? " · required" : "")")
                            .font(.maryMono(9.5))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.maryInk.opacity(0.06)))
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(action.steps.enumerated()), id: \.element.id) { index, step in
                        blockRow(index + 1, step, isUnverified: action.isUnverified(step))
                    }
                    if !action.cleanupSteps.isEmpty {
                        StudioLabel("Afterwards")
                            .padding(.top, 4)
                        ForEach(Array(action.cleanupSteps.enumerated()), id: \.element.id) { index, step in
                            blockRow(index + 1, step, isUnverified: action.isUnverified(step))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 210)

            if !action.unverifiedStepIDs.isEmpty {
                StudioNote("The flagged blocks name something Seer was not shown — a menu that only opens on click. Run them once against the real window before you keep them.")
            }
        }
    }

    private func blockRow(
        _ number: Int,
        _ step: PluginRecipeStepSchema,
        isUnverified: Bool
    ) -> some View {
        HStack(spacing: .layer2) {
            Text("\(number)")
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.3))
                .frame(width: 11, alignment: .trailing)
            Text(step.kind.editorTitle)
                .font(.marySans(10.5))
                .foregroundStyle(Color.maryInk)
            Text(Self.arguments(step))
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: .layer1)
            if step.text?.input != nil {
                MaryBadge(text: "bound", color: .maryGreen)
            }
            if isUnverified {
                MaryBadge(text: "verify", color: .maryGold)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isUnverified ? Paper.highlight.opacity(0.18) : Color.maryCard))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.maryBorder, lineWidth: 1))
    }

    /// One line saying what a block actually does, in the schema's own terms.
    static func arguments(_ step: PluginRecipeStepSchema) -> String {
        switch step.kind {
        case .keyChord:
            let modifiers = step.modifiers.map(\.rawValue).joined(separator: "+")
            let key = step.key?.rawValue ?? "?"
            return modifiers.isEmpty ? key : "\(modifiers)+\(key)"
        case .typeText:
            if let input = step.text?.input { return "input: \(input)" }
            return step.text?.value.map { "\u{201C}\($0)\u{201D}" } ?? ""
        case .wait:
            return "\(step.durationSeconds ?? 0)s"
        case .captureAccessibilityAnchor:
            guard let locator = step.accessibilityLocator else { return "" }
            var text = "\(locator.role.rawValue) \u{201C}\(locator.identifier)\u{201D}"
            if let descendant = locator.descendantRole {
                text += " ▸ \(descendant.rawValue)"
            }
            return text
        case .scroll:
            return "dx \(step.deltaX?.value ?? 0) · dy \(step.deltaY?.value ?? 0)"
        case .pointerMove, .pointerClick, .pointerDrag, .pointerSquareDrag:
            return "at the captured anchor"
        case .rebindFocusedWindow:
            return "if the window changed"
        }
    }

    private func refusal(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: .layer3) {
            HStack(spacing: .layer2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.maryError)
                Text("This one needs a faculty")
                    .font(.marySans(12, weight: .medium))
                    .foregroundStyle(Color.maryInk)
            }
            Text(reason)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            StudioNote("Hands click, type, scroll and wait — they never hand a value back. Reading something out of an application needs a faculty compiled into Mary, and the Studio cannot write one. Seer says so rather than inventing blocks that would silently do nothing.")
            MaryBadge(text: "needs a Mary faculty", color: .maryError)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: .layer2) {
            StudioNote("Accepting writes through the same check a hand-built action goes through.")
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.maryQuiet)
            if case .drafted = outcome {
                Button("Draft again", action: run)
                    .buttonStyle(.maryQuiet)
                Button("Add to \(package.ability.title)", action: accept)
                    .buttonStyle(.mary)
            } else {
                Button(isDrafting ? "Drafting…" : "Draft it", action: run)
                    .buttonStyle(.mary)
                    .disabled(!canDraft)
                    .opacity(canDraft ? 1 : 0.4)
            }
        }
    }

    private var canDraft: Bool {
        !isDrafting
            && seerIsReady != false
            && !goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func stepTitle(_ number: Int, _ text: String) -> some View {
        HStack(spacing: .layer2) {
            Text("\(number)")
                .font(.marySans(9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.maryGold))
            SectionLabel(text)
        }
    }

    // MARK: - Actions

    private func run() {
        failure = nil
        outcome = nil
        isDrafting = true
        let frames = (capture?.frames ?? []).filter { selectedFrames.contains($0.id) }
        let goal = goal
        let application = applicationTitle
        Task {
            do {
                let result = try await drafter.draft(
                    goal: goal,
                    application: application,
                    frames: frames)
                outcome = result
            } catch {
                failure = error.localizedDescription
            }
            isDrafting = false
        }
    }

    private func accept() {
        guard case .drafted(let action)? = outcome else { return }
        let added = model.mutateAuthoringDocument { document in
            _ = try document.addRemoteHandsAction(
                title: action.title,
                summary: action.summary,
                inputs: action.inputs,
                steps: action.steps,
                cleanupSteps: action.cleanupSteps)
        }
        if added { dismiss() }
    }
}
