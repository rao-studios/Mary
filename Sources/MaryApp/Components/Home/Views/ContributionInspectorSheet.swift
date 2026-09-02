//
//  ContributionInspectorSheet.swift
//  Mary
//
//  WHAT: Tap a brushstroke → totem contribution for that span.
//  PIN:  Content preview is a search heuristic (Totem has no content-by-id).
//

import MaryBrain
import MaryTotem
import SwiftUI
import MaryRuntime

struct ContributionInspectorSheet: View {
    let owner: SeerContribution.Owner
    /// The assistant reply this owner contributed to (span-text search seed).
    let responseText: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ContributionInspectorViewModel()

    private var royaltyPercent: String {
        String(format: "%.0f%%", owner.royalty * 100)
    }

    private var sortedDocumentIDs: [String] {
        owner.documentIDs.sorted {
            (owner.influence[$0] ?? 0) > (owner.influence[$1] ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header

                MaryCard {
                    VStack(alignment: .leading, spacing: .layer3) {
                        SectionLabel("Contribution")
                        HStack(spacing: .layer4) {
                            stat("Royalty", royaltyPercent)
                            stat("Documents", "\(owner.documentIDs.count)")
                            stat("Passages", "\(owner.spans.count)")
                            Spacer()
                        }
                        Text("Totem \(owner.totemID)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.maryInk.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                MaryCard {
                    VStack(alignment: .leading, spacing: .layer3) {
                        SectionLabel("Sources")
                        if viewModel.isLoading {
                            HStack(spacing: .layer2) {
                                ProgressView().controlSize(.small)
                                Text("Reading the totem…")
                                    .font(.marySans(11))
                                    .foregroundStyle(Color.maryInk.opacity(0.5))
                            }
                        }
                        ForEach(sortedDocumentIDs, id: \.self) { documentID in
                            documentRow(documentID)
                        }
                        if !viewModel.isLoading, sortedDocumentIDs.isEmpty {
                            Text("No document detail available.")
                                .font(.marySans(11))
                                .foregroundStyle(Color.maryInk.opacity(0.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.layer4)
        }
        .background(Paper.page)
        .marySheet(ideal: CGSize(width: 440, height: 480))
        .task {
            await viewModel.load(owner: owner, responseText: responseText)
        }
    }

    private var header: some View {
        HStack {
            MaryMark(size: 18)
            Text("From the totem")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.mary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.marySerif(16, weight: .medium))
                .foregroundStyle(Color.maryInk)
            Text(label)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }
    }

    private func documentRow(_ documentID: String) -> some View {
        let influence = owner.influence[documentID] ?? 0
        let detail = viewModel.documents[documentID]
        return VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer3) {
                Text(detail?.name ?? "Document \(documentID.prefix(8))…")
                    .font(.marySans(12, weight: .medium))
                    .foregroundStyle(Color.maryInk)
                    .lineLimit(1)
                if let group = detail?.groupLabel {
                    Text(group.uppercased())
                        .font(.marySans(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.maryGold)
                        .padding(.horizontal, .layer2)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().strokeBorder(Color.maryGold.opacity(0.45), lineWidth: 1)
                        )
                }
                Spacer()
                Text(String(format: "%.0f%%", influence * 100))
                    .font(.marySans(11, weight: .medium))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.maryInk.opacity(0.08))
                    Capsule()
                        .fill(Color.maryGold.opacity(0.6))
                        .frame(width: max(2, geo.size.width * influence))
                }
            }
            .frame(height: 4)
            if let preview = detail?.preview {
                Text(preview)
                    .font(.marySerif(12, weight: .light, italic: true))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                    .lineLimit(3)
            }
        }
        .padding(.vertical, .layer1)
    }
}

// MARK: - View model

@MainActor
final class ContributionInspectorViewModel: ObservableObject {

    struct DocumentDetail {
        var name: String?
        var groupLabel: String?
        var preview: String?
    }

    @Published var documents: [String: DocumentDetail] = [:]
    @Published var isLoading = false

    func load(owner: SeerContribution.Owner, responseText: String) async {
        isLoading = true
        defer { isLoading = false }
        let reader = MaryRuntime.makeTotemReader()
        var ownerID = owner.ownerID ?? ""
        if ownerID.isEmpty {
            ownerID = await MaryRuntime.seerSession.userID ?? ""
        }
        let documentIDs = Array(owner.documentIDs)
        guard !ownerID.isEmpty, !documentIDs.isEmpty else { return }

        // Primary: real content by id (TotemLibrary.Documents).
        if let contents = try? await reader.documents(ids: documentIDs, ownerID: ownerID),
           !contents.isEmpty {
            for document in contents {
                documents[document.id] = DocumentDetail(
                    name: document.name.isEmpty ? nil : document.name,
                    groupLabel: document.groupLabel.isEmpty ? nil : document.groupLabel,
                    preview: String(document.content.prefix(300))
                )
            }
            return
        }

        // Fallback (Totem binary predating the Documents RPC): library
        // metadata + span-text search heuristic.
        if let groups = try? await reader.groups(containing: documentIDs, ownerID: ownerID) {
            for group in groups {
                for document in group.documents where owner.documentIDs.contains(document.id) {
                    documents[document.id, default: DocumentDetail()].name =
                        document.name.isEmpty ? nil : document.name
                    documents[document.id, default: DocumentDetail()].groupLabel = group.label
                }
            }
        }
        let seed = owner.spans.first.flatMap { span -> String? in
            guard let range = span.range(in: responseText) else { return nil }
            return String(responseText[range].prefix(200))
        } ?? String(responseText.prefix(200))
        guard !seed.isEmpty else { return }
        if let hits = try? await reader.search(query: seed, ownerID: ownerID, topK: 12) {
            for hit in hits where owner.documentIDs.contains(hit.documentID) {
                if documents[hit.documentID, default: DocumentDetail()].preview == nil {
                    documents[hit.documentID, default: DocumentDetail()].preview = hit.text
                }
            }
        }
    }
}
