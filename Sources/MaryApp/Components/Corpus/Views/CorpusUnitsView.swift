//
//  CorpusUnitsView.swift
//  Mary
//
//  What was actually ingested, and the three things you can do about it:
//  correct its labels, make it re-read the file, or take it back entirely.
//

import MaryAmbient
import SwiftUI
import MaryRuntime

struct CorpusUnitsView: View {

    @ObservedObject var vm: CorpusViewModel
    @Binding var selectedUnitKey: String?

    @State private var labelDraft: String = ""
    @State private var confirmForget: UnitIndexRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            if vm.units.isEmpty {
                empty
            } else {
                ForEach(vm.units) { row in
                    unitCard(row)
                }
            }
        }
        .padding(.horizontal, .layer4)
        .confirmationDialog(
            "Forget \(confirmForget?.relativePath ?? "")?",
            isPresented: Binding(
                get: { confirmForget != nil },
                set: { if !$0 { confirmForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive) {
                if let record = confirmForget { forget(record) }
                confirmForget = nil
            }
            Button("Keep it", role: .cancel) { confirmForget = nil }
        } message: {
            Text("Mary drops what she learned about this file and removes it from the totem. She'll learn it again the next time you open it. This can't be undone.")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            Text("Nothing indexed yet.")
                .font(.marySans(12, weight: .medium))
            // NO APPLICATION NAMED. Which applications have a corpus is a
            // fact about the installed packages, and this sentence would have
            // to be edited every time one arrives — the Schema tab lists them
            // from the declarations instead.
            Text("Open a project in an application that declares a corpus, edit a file, and stay on it for about fifteen seconds. Mary waits for you to settle before reading anything.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.55))
        }
        .padding(.top, .layer4)
    }

    private func unitCard(_ row: CorpusUnitRow) -> some View {
        let record = row.record
        let isOpen = selectedUnitKey == record.unitKey
        return MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedUnitKey = isOpen ? nil : record.unitKey
                    labelDraft = record.labels.joined(separator: ", ")
                } label: {
                    header(record, row: row, isOpen: isOpen)
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider()
                    detail(record)
                    actions(record)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(
        _ record: UnitIndexRecord, row: CorpusUnitRow, isOpen: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: .layer2) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                Text((record.relativePath as NSString).lastPathComponent)
                    .font(.marySans(12, weight: .medium))
                    .lineLimit(1)
                if record.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.maryGold)
                }
                Spacer()
                Text(record.indexedAt, style: .relative)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
            }
            Text(row.statusLine)
                .font(.marySans(10))
                .foregroundStyle(
                    row.isStale ? Color.maryError : Color.maryInk.opacity(0.5))
            if !record.labels.isEmpty {
                Text(record.labels.joined(separator: " · "))
                    .font(.maryMono(10))
                    .foregroundStyle(Color.maryInk.opacity(0.65))
            }
        }
    }

    private func detail(_ record: UnitIndexRecord) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            field("Path", record.relativePath)
            if let precis = record.precis, !precis.isEmpty {
                field("Summary", precis)
            }
            if !record.declaredTypes.isEmpty {
                field("Declares", record.declaredTypes.joined(separator: ", "))
            }
            if !record.neighbours.isEmpty {
                field(
                    "Related",
                    record.neighbours
                        .map { ($0 as NSString).lastPathComponent }
                        .joined(separator: ", "))
            }
            if !record.apiHeaders.isEmpty {
                field("Signatures", "\(record.apiHeaders.count) kept")
            }
            field("Revision", record.contentHash)
            field("Totem", record.deposit.rawValue)
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name.uppercased())
                .font(.maryMono(8))
                .foregroundStyle(Color.maryInk.opacity(0.35))
            Text(value)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.8))
                .textSelection(.enabled)
        }
    }

    private func actions(_ record: UnitIndexRecord) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LABELS")
                    .font(.maryMono(8))
                    .foregroundStyle(Color.maryInk.opacity(0.35))
                HStack(spacing: .layer2) {
                    TextField("ordering, gating", text: $labelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.maryMono(10))
                    Button("Pin") { pin(record) }
                        .buttonStyle(.maryQuiet)
                }
                Text("Pinned labels replace the summariser's for this file, every time it changes.")
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            HStack(spacing: .layer2) {
                Button("Re-index") { reindex(record) }
                    .buttonStyle(.maryQuiet)
                Button("Forget") { confirmForget = record }
                    .buttonStyle(.maryQuiet)
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func pin(_ record: UnitIndexRecord) {
        let labels = labelDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Task {
            let notice = await MaryRuntime.pinUnitLabels(
                labels, unitKey: record.unitKey, path: record.relativePath,
                projectID: record.projectID, projectName: record.projectName)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }

    private func reindex(_ record: UnitIndexRecord) {
        Task {
            let notice = await MaryRuntime.reindexUnit(
                path: record.relativePath, projectID: record.projectID,
                projectName: record.projectName)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }

    private func forget(_ record: UnitIndexRecord) {
        Task {
            let notice = await MaryRuntime.forgetUnit(
                unitKey: record.unitKey, path: record.relativePath,
                projectID: record.projectID, projectName: record.projectName)
            await MainActor.run {
                vm.notice = notice
                selectedUnitKey = nil
                vm.refresh()
            }
        }
    }
}
