//
//  DebuggerPaneView.swift
//  Mary
//
//  The minimap pane: window thumbnails across every Space, each captioned
//  with what Mary's watcher actually parsed — or the honest reason it
//  can't see. Plain view owning the realtime view models (the Home ↔
//  HomeSessionView split, replayed): Granite state stays click-scoped,
//  the 1–2 Hz repaint lives here. Captions and the inspector both render
//  from PerceptionSnapshotViewModel's cards — one source, never two.
//

import MaryBrain
import SwiftUI
import MaryRuntime

struct DebuggerPaneView: View {
    @Binding var selectedWindowID: UInt32?
    /// Inspector target (PerceptionWorld.rawValue) — written on tile tap.
    @Binding var selectedWorld: String?
    /// The filter bar's tab and capture scope, as EyesFilter/CaptureScope
    /// tokens. THE source of truth is Debugger.Center; the minimap view model
    /// only receives pushed copies to parameterise its sweep (see
    /// DebuggerMinimapViewModel — poll inputs, never a second state).
    @Binding var filterToken: String?
    @Binding var captureScopeToken: String?

    @StateObject var vm = DebuggerMinimapViewModel()
    @StateObject var perceptionVM = PerceptionSnapshotViewModel()

    let grid = [GridItem(.adaptive(minimum: 150), spacing: .layer3)]
    /// Icon chips, WRAPPED — not a horizontal scroller. The pane's content
    /// floor is ~268 pt (300 minWidth − 2×.layer4), which fits about two and
    /// a half text tabs; the app hides scroll indicators everywhere, so
    /// off-screen tabs would be invisible; and a horizontal scroller nested
    /// in this vertical one is a trackpad coin-flip. 28 pt columns wrap ~8
    /// per row at the floor.
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
