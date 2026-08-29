//
//  TotemsLibraryView.swift
//  Mary
//
//  What the totem holds, by lane and family: chips over the families that
//  actually exist, lane sections of paged groups, and a two-tier document
//  drill. The drill replaces the listing rather than sitting beside it —
//  the pane is a narrow column, and a body deserves its width.
//

import SwiftUI
import MaryRuntime

struct TotemsLibraryView: View {

    @ObservedObject var vm: TotemExplorerViewModel
    @Binding var laneFilter: String?
    @Binding var selectedGroupID: String?
    @Binding var selectedDocumentID: String?

    private var filterFamily: TotemAddressFamily? {
        laneFilter.flatMap(TotemAddressFamily.init(rawValue:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            if let document = vm.selectedDocument {
                documentDetail(document)
            } else {
                listing
            }
        }
        .padding(.horizontal, .layer4)
        .onAppear {
            // A noticed-but-empty state refetches too — loadLibrary(reset:)
            // clears the notice, and the loading flag is the loop guard.
            // onAppear fires once per tab entry, so a dead server costs one
            // probe per visit, never a spin.
            if vm.laneSections.isEmpty, !vm.isLoadingLibrary {
                vm.loadLibrary(reset: true)
            }
        }
    }

    // MARK: - Listing

    @ViewBuilder
    private var listing: some View {
        if let notice = vm.libraryNotice {
            HStack(alignment: .firstTextBaseline, spacing: .layer2) {
                Text(notice)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryError)
                // The in-pane way out: without it a failed first fetch stayed
                // failed until the pane closed.
                Button("Retry") { vm.loadLibrary(reset: true) }
                    .buttonStyle(.maryQuiet)
            }
        }

        if !vm.familyChips.isEmpty {
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(vm.familyChips) { chip in
                    MaryChip(
                        label: "\(chip.title) \(chip.count)",
                        isOn: laneFilter == chip.family.rawValue
                    ) {
                        // Tapping the active chip clears it — nil means all.
                        laneFilter = laneFilter == chip.family.rawValue
                            ? nil : chip.family.rawValue
                    }
                }
            }
        }

        let sections = TotemExplorerViewModel.sections(
            vm.laneSections, matching: filterFamily)
        ForEach(sections) { section in
            laneSection(section)
        }

        if vm.isLoadingLibrary {
            HStack(spacing: .layer2) {
                ProgressView().controlSize(.small)
                Text("Reading the library…")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
        } else if sections.isEmpty, vm.libraryNotice == nil {
            Text("Nothing here yet. Groups appear as Mary deposits into the totem.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.5))
                .padding(.top, .layer4)
        }

        if vm.libraryHasMore, !vm.isLoadingLibrary {
            Button("Load more") { vm.loadMore() }
                .buttonStyle(.maryQuiet)
        }
    }

    private func laneSection(_ section: TotemLaneSection) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            SectionLabel(section.title)
                .padding(.top, .layer2)
            Text(section.subtitle)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
            ForEach(section.groups) { group in
                groupCard(group)
            }
        }
    }

    private func groupCard(_ group: TotemGroupRow) -> some View {
        let isOpen = selectedGroupID == group.id
        return MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedGroupID = isOpen ? nil : group.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: .layer2) {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                            Text(group.label)
                                .font(.marySans(12, weight: .medium))
                                .lineLimit(1)
                            MaryBadge(text: group.familyTitle)
                            if group.isLegacy {
                                MaryBadge(text: "legacy")
                            }
                            Spacer()
                            Text("\(group.documentCount)")
                                .font(.maryMono(9))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                        }
                        Text(group.id)
                            .font(.maryMono(9))
                            .foregroundStyle(Color.maryInk.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider()
                    if group.documents.isEmpty {
                        Text("No documents in this group.")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                    ForEach(group.documents) { document in
                        documentRow(document)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func documentRow(_ document: TotemDocumentRow) -> some View {
        Button {
            selectedDocumentID = document.id
            vm.loadDocument(id: document.id)
        } label: {
            HStack(spacing: .layer2) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                Text(document.name)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let createdAt = document.createdAt {
                    Text(createdAt, style: .relative)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

    // MARK: - Document drill

    private func documentDetail(_ document: TotemDocumentDetail) -> some View {
        VStack(alignment: .leading, spacing: .layer3) {
            Button {
                vm.clearSelectedDocument()
                selectedDocumentID = nil
            } label: {
                HStack(spacing: .layer1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9))
                    Text("Library")
                        .font(.marySans(11))
                }
                .foregroundStyle(Color.maryInk.opacity(0.6))
            }
            .buttonStyle(.plain)

            MaryCard {
                VStack(alignment: .leading, spacing: .layer2) {
                    HStack(spacing: .layer2) {
                        Text(document.name)
                            .font(.marySans(13, weight: .medium))
                            .lineLimit(2)
                        MaryBadge(text: TotemExplorerViewModel.familyTitle(document.family))
                        Spacer()
                    }
                    if !document.groupLabel.isEmpty {
                        Text(document.groupLabel)
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryGold)
                    }
                    if let createdAt = document.createdAt {
                        Text(createdAt, style: .relative)
                            .font(.maryMono(9))
                            .foregroundStyle(Color.maryInk.opacity(0.4))
                    }
                    Text(document.id)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let notice = document.notice {
                        // The fallback tier answered — say so, in place.
                        Text(notice)
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryGold)
                    }

                    if vm.isLoadingDocument {
                        HStack(spacing: .layer2) {
                            ProgressView().controlSize(.small)
                            Text("Reading the totem…")
                                .font(.marySans(11))
                                .foregroundStyle(Color.maryInk.opacity(0.5))
                        }
                    }

                    if let body = document.body {
                        Divider()
                        Text(body)
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk.opacity(0.8))
                            .textSelection(.enabled)
                    } else if let preview = document.preview {
                        Divider()
                        Text(preview)
                            .font(.marySerif(12, weight: .light, italic: true))
                            .foregroundStyle(Color.maryInk.opacity(0.6))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
