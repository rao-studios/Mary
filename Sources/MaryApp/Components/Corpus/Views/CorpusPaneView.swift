//
//  CorpusPaneView.swift
//  Mary
//
//  WHAT: Corpus frame — sticky bar, three tabs, last-change notice.
//  OUT:  CorpusUnits / Profile / Operations / Schema
//

import MaryAmbient
import SwiftUI

struct CorpusPaneView: View {

    @Binding var tab: String
    @Binding var selectedUnitKey: String?
    @Binding var selectedProjectID: String?
    @Binding var showsRawSchema: Bool
    @Binding var selectedSubject: String?

    @StateObject private var vm = CorpusViewModel()

    private var selectedTab: CorpusTab {
        CorpusTab(rawValue: tab) ?? .units
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                if let notice = vm.notice {
                    Text(notice)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.75))
                        .padding(.horizontal, .layer4)
                        .padding(.top, .layer3)
                }
                switch selectedTab {
                case .units:
                    CorpusUnitsView(vm: vm, selectedUnitKey: $selectedUnitKey)
                case .profile:
                    CorpusProfileView(vm: vm)
                case .schema:
                    CorpusSchemaView(
                        vm: vm,
                        showsRaw: $showsRawSchema,
                        selectedSubject: $selectedSubject)
                case .operations:
                    CorpusOperationsView(vm: vm)
                }
            }
            .padding(.bottom, .layer4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // Its own backing, or it blends into the conversation column.
        .background(Paper.page)
        .safeAreaInset(edge: .top) { filterBar }
        .onAppear {
            vm.selectedProjectID = selectedProjectID
            vm.start()
        }
        .onDisappear { vm.stop() }
        .onChange(of: selectedProjectID) { _, value in
            vm.selectedProjectID = value
        }
    }

    // MARK: - Bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Text("Corpus")
                    .font(.marySerif(15, weight: .light, italic: true))
                    .foregroundStyle(Paper.ink.opacity(0.85))
                Spacer()
                Button {
                    vm.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }

            Picker("", selection: $tab) {
                ForEach(CorpusTab.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedTab == .units, !vm.projects.isEmpty {
                projectPicker
            }
            if selectedTab == .schema {
                Picker("", selection: $showsRawSchema) {
                    Text("Visual").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, .layer4)
        .padding(.vertical, .layer2)
        .background(Paper.page)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.maryBorder)
                .frame(height: 1)
        }
    }

    private var projectPicker: some View {
        FlowLayout(spacing: .layer1) {
            MaryChip(
                label: "All",
                isOn: selectedProjectID == nil,
                action: { selectedProjectID = nil })
            ForEach(vm.projects) { project in
                MaryChip(
                    label: "\(project.name) · \(project.unitCount)",
                    isOn: selectedProjectID == project.id,
                    action: { selectedProjectID = project.id })
            }
        }
    }
}
