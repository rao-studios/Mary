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
    @State private var showBench = true

    var body: some View {
        Group {
            switch phase {
            case .gate:
                AccessibilityTrustGate {
                    host.start()
                    trace.start()
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
                        WireframeStageView(model: model, trace: trace)
                            .frame(minWidth: 420)
                        if showBench {
                            SandBenchView(
                                host: host, trace: trace, model: model,
                                targetBundleID: row.bundleID)
                        }
                    }
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
