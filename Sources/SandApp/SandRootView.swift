//
//  SandRootView.swift
//  Sand
//
//  WHAT: The three phases — grant, pick, watch.
//  OUT:  AccessibilityTrustGate → TargetPickerView → the stage + the bench
//  PIN:  The runtime host starts as soon as the gate clears, not when the
//        first run happens: reading the ability graph takes long enough that
//        doing it inside a Run press would look like the recipe was slow.
//        `--target` skips the picker (see SandLaunchOptions); it never skips
//        the gate, because a bench with no grant must say so before it draws
//        an empty wireframe and lets someone conclude the app is empty.
//
import SwiftUI

struct SandRootView: View {
    private enum Phase {
        case gate
        case picking
        case watching(RunningAppRow)
    }

    @State private var phase: Phase = .gate
    @StateObject private var model = WireframeViewModel()
    @StateObject private var host = SandRuntimeHost()
    @StateObject private var trace = SandTraceModel()
    @StateObject private var turn = SandTurnHost()
    @State private var showBench = true
    /// `--run` names a skill outright, which is the direct lane's gesture;
    /// `--say` is a turn. Opening on the wrong one made `--run` look broken.
    @State private var lane: Lane =
        SandLaunchOptions.current.run != nil ? .direct : .turn

    /// TWO WAYS TO REACH THE HANDS, and the difference is the point. The turn
    /// lane goes through Mary's own routing, so what may be called is what the
    /// utterance earned. The direct lane calls a name outright — useful for
    /// exercising hands, honest about skipping the roster.
    private enum Lane: String, CaseIterable, Identifiable {
        case turn = "Turn"
        case direct = "Direct"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch phase {
            case .gate:
                AccessibilityTrustGate {
                    host.start()
                    trace.start()
                    turn.start(runtimeHost: host, trace: trace)
                    // The turn's ambient surface comes from the walk the stage
                    // already made — no second lane of AX reads.
                    turn.stagedSurface = { [weak model] in
                        guard let snapshot = model?.latest else { return nil }
                        return (snapshot, snapshot.bundleID)
                    }
                    phase = .picking
                    autoPickIfAsked()
                }
            case .picking:
                TargetPickerView(host: host) { row in
                    watch(row)
                }
            case .watching(let row):
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            model.stop()
                            trace.clear()
                            host.setStageTarget(bundleID: nil)
                            phase = .picking
                        } label: {
                            Label("Choose another app", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(row.name).font(.headline)
                        if let package = host.package(forBundleID: row.bundleID) {
                            Text(package.title)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor.opacity(0.18)))
                        }
                        Spacer()
                        Toggle("Bench", isOn: $showBench).toggleStyle(.button)
                    }
                    .padding(10)
                    Divider()
                    HSplitView {
                        WireframeStageView(model: model, trace: trace, host: host)
                            .frame(minWidth: 420)
                        if showBench {
                            VStack(spacing: 0) {
                                Picker("Lane", selection: $lane) {
                                    ForEach(Lane.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                switch lane {
                                case .turn:
                                    SandTurnView(host: turn, runtimeHost: host)
                                        .frame(minWidth: 380)
                                case .direct:
                                    SandBenchView(
                                        host: host, trace: trace, model: model,
                                        targetBundleID: row.bundleID)
                                }
                            }
                        }
                    }
                }
                // A TURN CAN READ A PAGE TOO, and its dispatches never pass through
                // `host.dispatch` — so the end of a turn is its own moment to pull the
                // roster back. Still never a poll: see `browserRoster`'s PIN.
                .onChange(of: turn.isRunning) { _, running in
                    if !running { model.refreshBrowserRoster() }
                }
            }
        }
    }

    private func watch(_ row: RunningAppRow) {
        model.start(pid: row.pid, bundleID: row.bundleID, name: row.name)
        // The runtime resolves providers against the lead, and on this bench
        // the lead is whatever the person just pointed at.
        host.setStageTarget(bundleID: row.bundleID)
        phase = .watching(row)
    }

    /// `--target <bundle id>`: pick without a click. A bundle id that is not
    /// running leaves the picker up rather than failing — the app may simply
    /// not have launched yet, and the roster is the honest place to say so.
    private func autoPickIfAsked() {
        guard let wanted = SandLaunchOptions.current.targetBundleID else { return }
        let roster = RunningAppRoster()
        guard let row = roster.apps.first(where: { $0.bundleID == wanted }) else { return }
        watch(row)
    }
}
