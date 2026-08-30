//
//  DebuggerPaneView.swift
//  Mary
//
//  WHAT: Minimap — window thumbnails + watcher captions (or why blind).
//  OUT:  PerceptionSnapshotViewModel cards (captions and inspector share them)
//

import MaryBrain
import SwiftUI
import MaryRuntime

struct DebuggerPaneView: View {
    @Binding var selectedWindowID: UInt32?
    /// Inspector target (PerceptionWorld.rawValue) — written on tile tap.
    @Binding var selectedWorld: String?
    /// Tab/scope tokens; Debugger.Center is truth, VM gets pushed copies.
    @Binding var filterToken: String?
    @Binding var captureScopeToken: String?

    @StateObject var vm = DebuggerMinimapViewModel()
    @StateObject var perceptionVM = PerceptionSnapshotViewModel()

    let grid = [GridItem(.adaptive(minimum: 150), spacing: .layer3)]
    /// Wrapped 28 pt icon chips; the pane hides scroll indicators.
    let tabGrid = [GridItem(.adaptive(minimum: 28), spacing: .layer1)]

    var filter: EyesFilter { EyesFilter(token: filterToken) }
    var captureScope: CaptureScope { CaptureScope(token: captureScopeToken) }

    /// What the body renders. The SWEEP stays whole — `vm.model.groups` is
    /// what the tab bar itself is built from.
    var visibleGroups: [AppTileGroup] {
        filter.visibleGroups(
            vm.model.groups,
            watchedBundleIDs: DebuggerMinimapViewModel.watchedBundleIDs,
            watchedBundlePrefixes: DebuggerMinimapViewModel.watchedBundlePrefixes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                if case .degraded(let reason) = vm.model.mode {
                    degradedBanner(reason)
                }
                ForEach(visibleGroups) { group in
                    groupSection(group)
                }
                if visibleGroups.isEmpty, !vm.model.groups.isEmpty {
                    emptyFilterNote
                }
                inspectorSlot
            }
            .padding(.layer4)
        }
        .scrollIndicators(.hidden)
        // Same register as the conversation column's voiceBar: an inset, so
        // the bar never scrolls away from the content it filters.
        .safeAreaInset(edge: .top) { filterBar }
        // Own backing — without it the pane inherits the root page and
        // blends into the conversation column.
        .background(Paper.page)
        // Belt and braces with the @StateObject teardown: closing the split
        // stops the polls either way — no pane, no WindowServer traffic.
        .onAppear {
            vm.start()
            perceptionVM.start()
            pushFilter()
        }
        .onDisappear {
            vm.stop()
            perceptionVM.stop()
        }
        .onChange(of: filterToken) { _, _ in pushFilter() }
        .onChange(of: captureScopeToken) { _, _ in vm.setCaptureScope(captureScope) }
        // App quit / last window closed: a filter pinned to a group that left
        // the sweep would render an empty pane whose only way out is knowing
        // which chip vanished. The fallback rule is pure and pinned.
        .onChange(of: vm.model.groups.map(\.id)) { _, _ in
            let resolved = filter.resolved(in: vm.model.groups)
            if resolved != filter { filterToken = resolved.token }
        }
    }

    /// One writer, one direction: Center → view model. Nothing reads the
    /// pushed copy back.
    func pushFilter() {
        vm.setFilter(filter)
        vm.setCaptureScope(captureScope)
    }

}
