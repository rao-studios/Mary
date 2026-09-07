//
//  ThreadsPaneView.swift
//  Mary
//
//  WHAT: Pane frame — sticky bar, five tabs, server-rack / Life doors.
//  OUT:  ThreadsNodes/Library/Graph/Ledger/Retrieval
//

import Granite
import SwiftUI
import MaryRuntime

struct ThreadsPaneView: View {

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

    @StateObject private var vm = ThreadExplorerViewModel()

    /// View-local sheet flag; Center would re-present on every rebuild.
    @State private var showsServers = false
    @State private var showsLife = false

    private var selectedTab: ThreadsTab {
        ThreadsTab(rawValue: tab) ?? .nodes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                switch selectedTab {
                case .nodes:
                    ThreadsNodesView(vm: vm, selectedNodeID: $selectedNodeID)
                case .library:
                    ThreadsLibraryView(
                        vm: vm,
                        laneFilter: $laneFilter,
                        selectedGroupID: $selectedGroupID,
                        selectedDocumentID: $selectedDocumentID)
                case .graph:
                    ThreadsGraphView(
                        vm: vm,
                        graphSeed: $graphSeed,
                        graphKindFilter: $graphKindFilter,
                        graphHops: $graphHops,
                        graphIncludesDocuments: $graphIncludesDocuments,
                        selectedEntityID: $selectedEntityID)
                case .ledger:
                    ThreadsLedgerView(vm: vm, selectedUnitKey: $selectedUnitKey)
                case .retrieval:
                    ThreadsRetrievalView(
                        vm: vm,
                        selectedExchangeID: $selectedExchangeID,
                        onOpenDocument: { id in
                            // The retrieval→library deep link: a cited
                            // document opens where documents live, with the
                            // drill fetch already in flight.
                            tab = ThreadsTab.library.rawValue
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
            // The Servers sheet is where the Thread port and node id change;
            // without a re-seed here, repairs keep POSTing to a dead port and
            // the live-node diff keeps the old identity.
            seedConfig()
        }) { ServersSheet() }
        .sheet(isPresented: $showsLife) { LifeCalibrationSheet() }
        .onAppear {
            // Seed node identity + repair port before start().
            seedConfig()
            vm.start()
        }
        // Backstop for edits that land outside the sheet — the silenced relay
        // still exposes current values whenever a VM diff re-renders the pane.
        .onChange(of: config.state.threadPort) { _, _ in seedConfig() }
        .onChange(of: config.state.threadNodeID) { _, _ in seedConfig() }
        .onChange(of: config.state.threadDataDir) { _, _ in seedConfig() }
        .onDisappear { vm.stop() }
    }

    /// One call site for every seed path — configure(...) is re-entrant, so
    /// re-seeding with unchanged values is safe.
    private func seedConfig() {
        vm.configure(
            nodeID: config.state.threadNodeID,
            port: config.state.threadPort,
            dataDir: config.state.threadDataDir)
    }

    // MARK: - Bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Text("Threads")
                    .font(.marySerif(15, weight: .light, italic: true))
                    .foregroundStyle(Paper.ink.opacity(0.85))
                Spacer()
                /*
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
                 */
                Button {
                    showsLife = true
                } label: {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                        .frame(width: 14, height: 14)
                        .overlay(alignment: .topTrailing) {
                            // Gold: a discipline is training. Ink: the idle
                            // engine is thinking or acting right now.
                            if vm.lifeIsTraining {
                                StatusDot(color: .maryGold)
                                    .offset(x: 3, y: -3)
                            } else if vm.lifePhase == .inferring || vm.lifePhase == .acting {
                                StatusDot(color: .maryInk)
                                    .offset(x: 3, y: -3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Life")
                .accessibilityLabel("Life")
                Button {
                    // Both entry points: the sync ledger pass answers now,
                    // the fleet/disk fetch lands when Sewn does.
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

            ViewThatFits(in: .horizontal) {
                Picker("", selection: $tab) {
                    ForEach(ThreadsTab.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Below the segmented control's minimum, every tab stays
                // reachable as chips that wrap instead of compressing.
                FlowLayout(spacing: .layer1) {
                    ForEach(ThreadsTab.allCases) { option in
                        MaryChip(label: option.title, isOn: option == selectedTab) {
                            tab = option.rawValue
                        }
                    }
                }
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
}
