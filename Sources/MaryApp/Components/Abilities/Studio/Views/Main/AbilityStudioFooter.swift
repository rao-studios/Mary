//
//  AbilityStudioFooter.swift
//  Mary
//
//  WHAT: Whether this ability can be saved, and what just happened.
//  IN:   AbilityStudioView shell.
//  OUT:  AbilityStudioValidationPresentation triage.
//  PIN:  Plain words. "Cannot save yet", never "invalid schema graph".
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioFooter: View {
    @ObservedObject var model: AbilityStudioViewModel
    let onShowIssues: () -> Void

    var body: some View {
        let presentation = AbilityStudioValidationPresentation(validation: model.validation)
        let errors = presentation.errors.count
        let advisories = presentation.actionableWarnings.count

        return HStack(spacing: .layer2) {
            Image(systemName: errors == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(errors == 0 ? Color.maryGreen : Color.maryError)
            Text(verdict(errors: errors))
                .foregroundStyle(errors == 0 ? Color.maryGreen : Color.maryError)
                .lineLimit(1)
                .layoutPriority(1)

            if errors > 0 || advisories > 0 {
                Button(action: onShowIssues) {
                    Text(counts(errors: errors, advisories: advisories))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                        .underline(errors > 0)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open Advanced to see them")
            }

            if model.isLocalDraft {
                // Below the compact span this collapses to the dot alone —
                // the sentence moves into `.help` rather than clipping.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: .layer2) {
                        dot
                        Text("Saving creates a local override")
                            .foregroundStyle(Color.maryInk.opacity(0.55))
                            .lineLimit(1)
                    }
                    dot
                }
                .help("The base package is immutable. Your copy lives in Application Support and shadows it.")
            }

            Spacer(minLength: .layer3)

            if let status = model.status {
                Text(status)
                    .foregroundStyle(Color.maryInk.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.marySans(10))
        .padding(.horizontal, .layer5)
        .padding(.vertical, 6)
        .background(Paper.page)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.maryBorder).frame(height: 1)
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(Color.maryInk.opacity(0.3))
    }

    private func verdict(errors: Int) -> String {
        guard errors == 0 else { return "Cannot save yet" }
        if model.isCreatingNewPackage { return "Ready for its first save" }
        return model.isDirty ? "Ready to save" : "Active"
    }

    private func counts(errors: Int, advisories: Int) -> String {
        var parts: [String] = []
        if errors > 0 {
            parts.append(errors == 1 ? "1 error" : "\(errors) errors")
        }
        if advisories > 0 {
            parts.append(advisories == 1 ? "1 advisory" : "\(advisories) advisories")
        }
        return parts.joined(separator: ", ")
    }
}
