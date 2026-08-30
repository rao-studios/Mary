//
//  TotemsPaneView.swift
//  Mary
//
//  The pane's frame: a bar that never scrolls away, five tabs, and the
//  server-rack / Life doors into the control room the navbar used to
//  open directly.
//

import Granite
import SwiftUI
import MaryRuntime

struct TotemsPaneView: View {

    @Binding var tab: String
    @Binding var selectedNodeID: String?
    @Binding var laneFilter: String?
    @Binding var selectedGroupID: String?
    @Binding var selectedDocumentID: String?
    @Binding var graphSeed: String
    @Binding var graphKindFilter: String?
    @Binding var graphHops: Int
    @Binding var graphIncludesDocuments: Bool
    @Binding var selectedEntityID: String?
    @Binding var selectedUnitKey: String?
    @Binding var selectedExchangeID: String?

    /// Silenced: the pane re-renders on VM diffs, not on config churn — the
    /// relay exists only to seed (and re-seed) the VM's two scalars below.
    @Relay(.silence) var config: ConfigService

    @StateObject private var vm = TotemExplorerViewModel()

    /// View-local by design (UtteranceView's inspector precedent): held in
    /// the Center this flag would re-present the sheet on every panel
    /// rebuild. Closing the panel mid-sheet dismisses the sheet with it —
    /// acceptable for a control room reached from inside the panel.
    @State private var showsServers = false
    @State private var showsLife = false

    private var selectedTab: TotemsTab {
        TotemsTab(rawValue: tab) ?? .nodes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                switch selectedTab {
                case .nodes:
                    TotemsNodesView(vm: vm, selectedNodeID: $selectedNodeID)
                case .library:
                    TotemsLibraryView(
                        vm: vm,
                        laneFilter: $laneFilter,
                        selectedGroupID: $selectedGroupID,
                        selectedDocumentID: $selectedDocumentID)
                case .graph:
                    TotemsGraphView(
                        vm: vm,
                        graphSeed: $graphSeed,
                        graphKindFilter: $graphKindFilter,
                        graphHops: $graphHops,
                        graphIncludesDocuments: $graphIncludesDocuments,
                        selectedEntityID: $selectedEntityID)
                case .ledger:
                    TotemsLedgerView(vm: vm, selectedUnitKey: $selectedUnitKey)
                case .retrieval:
                    TotemsRetrievalView(
                        vm: vm,
                        selectedExchangeID: $selectedExchangeID,
                        onOpenDocument: { id in
                            // The retrieval→library deep link: a cited
                            // document opens where documents live, with the
                            // drill fetch already in flight.
                            tab = TotemsTab.library.rawValue
                            selectedDocumentID = id
                            vm.loadDocument(id: id)
                        })
                }
            }
            .padding(.bottom, .layer4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // Its own backing, or it blends into the conversation column.
        .background(Paper.page)
        .safeAreaInset(edge: .top) { filterBar }
        .sheet(isPresented: $showsServers, onDismiss: {
            // The Servers sheet is where the Totem port and node id change;
            // without a re-seed here, repairs keep POSTing to a dead port and
            // the live-node diff keeps the old identity.
            seedConfig()
        }) { ServersSheet() }
        .sheet(isPresented: $showsLife) { LifeCalibrationSheet() }
        .onAppear {
            // Seeded BEFORE start(): the live-node identity diff and the
            // repair port ride these two scalars, and the VM cannot hold a
            // Granite relay itself. Unseeded it degrades to the persisted
            // node-id file and the default port, it does not break.
            seedConfig()
            vm.start()
        }
        // Backstop for edits that land outside the sheet — the silenced relay
        // still exposes current values whenever a VM diff re-renders the pane.
        .onChange(of: config.state.totemPort) { _, _ in seedConfig() }
        .onChange(of: config.state.totemNodeID) { _, _ in seedConfig() }
        .onDisappear { vm.stop() }
    }

    /// One call site for every seed path — configure(...) is re-entrant, so
    /// re-seeding with unchanged values is safe.
    private func seedConfig() {
        vm.configure(
            nodeID: config.state.totemNodeID,
            port: config.state.totemPort)
    }

    // MARK: - Bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Text("Totems")
                    .font(.marySerif(15, weight: .light, italic: true))
                    .foregroundStyle(Paper.ink.opacity(0.85))
                Spacer()
                Button {
                    showsServers = true
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Servers")
                .accessibilityLabel("Servers")
                Button {
                    showsLife = true
                } label: {
                    Image(systemName: "gauge.with.dots.needle")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                        .overlay(alignment: .topTrailing) {
                            if vm.lifeIsTraining {
                                StatusDot(color: .maryGold)
                                    .offset(x: 3, y: -3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Life")
                .accessibilityLabel("Life")
                Button {
                    // Both entry points: the sync ledger pass answers now,
                    // the fleet/disk fetch lands when Seer does.
                    vm.refresh()
                    Task { await vm.refreshNodes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }

            Picker("", selection: $tab) {
                ForEach(TotemsTab.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
}
