//
//  AbilityStudioIssuesSection.swift
//  Mary
//
//  WHAT: What the validator says, and where to go and fix it.
//  IN:   Advanced drawer.
//  OUT:  AbilityStudioIssueDestination → the pane's focus ring.
//  PIN:  Read-only. Provider coverage is separated out because it is not this
//        package's fault: a portable Skill stays honestly blocked until some
//        application realizes it.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioIssuesSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let onFocus: (AbilityStudioPane) -> Void

    @State private var showsAdvisories = false

    private var presentation: AbilityStudioValidationPresentation {
        AbilityStudioValidationPresentation(validation: model.validation)
    }

    var body: some View {
        let presentation = presentation
        let coverage = presentation.coverageGroups.flatMap(\.issues)

        AbilityStudioAdvancedSection(
            title: "Issues",
            count: presentation.errors.isEmpty ? "clean" : "\(presentation.errors.count)",
            startsOpen: !presentation.errors.isEmpty
        ) {
            if presentation.errors.isEmpty {
                HStack(alignment: .top, spacing: .layer2) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.maryGreen)
                        .padding(.top, 1)
                    Text("No errors. This ability validates against the active graph.")
                        .font(.marySans(10.5))
                        .foregroundStyle(Color.maryInk.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(presentation.errors) { issue in
                row(issue, tone: .maryError)
            }

            if !presentation.actionableWarnings.isEmpty || !coverage.isEmpty {
                Button {
                    showsAdvisories.toggle()
                } label: {
                    Text(showsAdvisories
                         ? "Hide advisories"
                         : "Show \(presentation.actionableWarnings.count + coverage.count) advisories")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryGold)
                }
                .buttonStyle(.plain)
            }

            if showsAdvisories {
                ForEach(presentation.actionableWarnings) { issue in
                    row(issue, tone: .maryGold)
                }
                ForEach(presentation.coverageGroups) { group in
                    VStack(alignment: .leading, spacing: .layer1) {
                        Text("\(group.packageID.rawValue) — \(group.unavailableSkillCount) skills waiting for hands")
                            .font(.marySans(10, weight: .medium))
                            .foregroundStyle(Color.maryInk.opacity(0.6))
                        Text("Not this ability's fault. A portable skill stays installed and honestly blocked until some application realizes it.")
                            .font(.marySans(9.5))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            StudioNote(
                "A recipe step naming another package's skill is not checked here — the validator checks syntax and this ability's own transitions. The Recipe pane resolves every row live for that reason.")
        }
    }

    private func row(_ issue: SchemaIssue, tone: Color) -> some View {
        let pane = AbilityStudioIssueDestination.pane(for: issue)
        return Button {
            onFocus(pane)
        } label: {
            HStack(alignment: .top, spacing: .layer2) {
                Circle()
                    .fill(tone)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.message)
                        .font(.marySans(10.5))
                        .foregroundStyle(Color.maryInk.opacity(0.78))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Text(AbilityStudioIssueDestination.where_(issue))
                            .font(.maryMono(8.5))
                            .foregroundStyle(Color.maryInk.opacity(0.35))
                        Text("· \(pane.title)")
                            .font(.marySans(9))
                            .foregroundStyle(Color.maryGold.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("Show me where — \(pane.title)")
    }
}
