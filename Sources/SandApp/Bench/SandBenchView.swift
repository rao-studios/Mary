//
//  SandBenchView.swift
//  Sand
//
//  WHAT: Pick a taught ability, run it, and watch where it goes.
//  IN:   SandRuntimeHost (the graph + dispatch), SandTraceModel (the timeline)
//  OUT:  the right-hand pane beside the wireframe
//  PIN:  ONE RUN AT A TIME, ON PURPOSE, stated plainly in the UI: a second
//        dispatch while the first holds the stage would interleave two
//        timelines and neither would be readable.
//        The cadence rises to `.running` for the duration, so the wireframe
//        catches what the recipe did rather than the state it left behind.
//
import MaryComputerUse
import MaryFoundation
import MaryPlugin
import SwiftUI

struct SandBenchView: View {
    @ObservedObject var host: SandRuntimeHost
    @ObservedObject var trace: SandTraceModel
    @ObservedObject var model: WireframeViewModel
    /// The bundle id of the app on the stage — used to pre-select its expertise.
    let targetBundleID: String?

    @State private var selectedPackage: PackageID?
    @State private var selectedRunnable: String?
    @State private var arguments: [String: String] = [:]
    @State private var observing = false
    @State private var runID: String?
    @State private var observer = SandObserverTail()
    /// `--run` fires once, after the graph has loaded and a target is on the
    /// stage. Guarded so a re-render never runs an ability twice.
    @State private var autoRan = false

    private var package: SandPackage? {
        guard let selectedPackage else { return host.package(forBundleID: targetBundleID) }
        return host.packages.first { $0.id == selectedPackage }
    }

    private var runnable: SandRunnable? {
        guard let package else { return nil }
        guard let selectedRunnable else { return package.runnables.first }
        return package.runnables.first { $0.id == selectedRunnable } ?? package.runnables.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // WHAT TO RUN scrolls; HOW IT WENT does not. A long package list
            // used to push the Run button off the bottom of the pane, which
            // made the one control this app exists for the hardest to reach.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    packagePicker
                    runnableList
                    argumentForm
                }
                .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                runControls
                outcomeBanner
                stepList
            }
            .padding(12)
            Divider()
            SandTimelineView(trace: trace)
                .frame(minHeight: 200)
        }
        .frame(minWidth: 380)
        .background(.background)
        .onChange(of: host.packages.count) { _, _ in runIfAsked() }
        .onAppear { runIfAsked() }
    }

    /// `--run <invocation>` — the same press the Run button makes, so a
    /// scripted run and a clicked one produce the same timeline.
    private func runIfAsked() {
        guard !autoRan,
              let wanted = SandLaunchOptions.current.run,
              !host.packages.isEmpty,
              let item = host.packages
                .flatMap(\.runnables)
                .first(where: { $0.invocation == wanted })
        else { return }
        autoRan = true
        selectedPackage = item.packageID
        selectedRunnable = item.id
        arguments = SandLaunchOptions.current.arguments
        run(item)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bench").font(.headline)
            Text(host.loadSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            grantChips
            Toggle("Observe", isOn: $observing)
                .toggleStyle(.button)
                .help("Also show what a running Mary process is doing (read-only)")
                .onChange(of: observing) { _, on in
                    if on {
                        observer.start { line in trace.receiveExternal(line) }
                    } else {
                        observer.stop()
                    }
                }
        }
        .padding(10)
    }

    /// The two grants that decide whether anything below can happen at all.
    /// A refused hand and an ungranted app look identical in an app that does
    /// not print this.
    @ViewBuilder
    private var grantChips: some View {
        if let snapshot = trace.snapshot {
            chip(
                "AX", snapshot.accessibilityTrusted,
                help: snapshot.accessibilityTrusted
                    ? "Accessibility granted to Sand"
                    : "Sand has no Accessibility grant — every hand will refuse")
            chip(
                "Screen", snapshot.screenRecordingGranted,
                help: "Screen Recording — only the one pixel read needs it")
        }
    }

    private func chip(_ label: String, _ granted: Bool, help: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((granted ? Color.green : Color.red).opacity(0.18)))
            .foregroundStyle(granted ? Color.green : Color.red)
            .help(help)
    }

    // MARK: - Choosing

    @ViewBuilder
    private var packagePicker: some View {
        if host.packages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No application expertise installed")
                    .foregroundStyle(.secondary)
                Text("""
                    Sand reads the same Abilities/ folder Mary does. Set \
                    MARY_ABILITIES_PATH to point it elsewhere.
                    """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Picker("Expertise", selection: Binding(
                get: { package?.id ?? host.packages[0].id },
                set: { selectedPackage = $0; selectedRunnable = nil; arguments = [:] }
            )) {
                ForEach(host.packages) { item in
                    Text("\(item.title) — \(item.applicationTitle)").tag(item.id)
                }
            }
            if let package, !package.summary.isEmpty {
                Text(package.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var runnableList: some View {
        if let package {
            if package.runnables.isEmpty {
                Text("This package carries no recipes and exposes no skills of its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(package.runnables) { item in
                        runnableRow(item, isSelected: item.id == runnable?.id)
                    }
                }
            }
        }
    }

    private func runnableRow(_ item: SandRunnable, isSelected: Bool) -> some View {
        Button {
            selectedRunnable = item.id
            arguments = [:]
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(isSelected ? .semibold : .regular)
                    Spacer()
                    if !host.isDispatchable(item.invocation) {
                        Text("not on the roster")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(kindWord(item))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(item.invocation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                    : nil)
        }
        .buttonStyle(.plain)
    }

    private func kindWord(_ item: SandRunnable) -> String {
        switch item.kind {
        case .recipe: return "\(item.steps.count) steps"
        case .skill: return "skill"
        }
    }

    // MARK: - Arguments

    @ViewBuilder
    private var argumentForm: some View {
        if let runnable {
            let parameters = host.parameters(forInvocation: runnable.invocation)
            if !runnable.inputs.isEmpty || !parameters.isEmpty {
                Divider()
                Text("Arguments").font(.caption).foregroundStyle(.secondary)
                ForEach(runnable.inputs, id: \.name) { input in
                    field(
                        name: input.name,
                        required: input.required,
                        options: input.enumValues,
                        placeholder: input.defaultValue ?? input.kind.rawValue)
                }
                ForEach(parameters, id: \.name) { parameter in
                    if !runnable.inputs.contains(where: { $0.name == parameter.name }) {
                        field(
                            name: parameter.name,
                            required: parameter.required,
                            options: parameter.enumValues,
                            placeholder: parameter.summary.isEmpty
                                ? parameter.type : parameter.summary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field(
        name: String, required: Bool, options: [String]?, placeholder: String
    ) -> some View {
        HStack {
            Text(name + (required ? " *" : ""))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            if let options, !options.isEmpty {
                Picker("", selection: binding(name)) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(placeholder, text: binding(name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(
            get: { arguments[name] ?? "" },
            set: { arguments[name] = $0 })
    }

    // MARK: - Running

    @ViewBuilder
    private var runControls: some View {
        if let runnable {
            HStack(spacing: 8) {
                Button(trace.isRunning ? "Running…" : "Run") { run(runnable) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trace.isRunning || !host.isDispatchable(runnable.invocation))
                Button("Stop") { stop() }
                    .disabled(!trace.isRunning)
                Button("Clear") { trace.clear() }
                    .disabled(trace.isRunning)
                Spacer()
            }
            if trace.snapshot?.accessibilityTrusted == false {
                Label(
                    "Sand has no Accessibility grant — the hands will refuse before they act.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func run(_ runnable: SandRunnable) {
        let identity = UUID().uuidString
        runID = identity
        trace.beginRun(runnable, runID: identity)
        // The recipe is about to move the target. Look harder while it does.
        model.setCadence(.running)
        Task {
            let outcome = await host.dispatch(
                name: runnable.invocation, arguments: arguments, runID: identity)
            trace.endRun(outcome: outcome, host: host, runID: identity)
            model.setCadence(.watching)
            runID = nil
        }
    }

    private func stop() {
        guard let runID else { return }
        host.cancel(runID: runID)
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        if let outcome = trace.lastOutcome {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: outcome.ok
                    ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.ok ? Color.green : Color.red)
                Text(outcome.summary).font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((outcome.ok ? Color.green : Color.red).opacity(0.10)))
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepList: some View {
        if !trace.steps.isEmpty {
            Divider()
            HStack {
                Text("Steps").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("matched by lane and order")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("""
                        The runtime does not say which act belongs to which step. \
                        This column pairs them by lane in order — a reading aid. \
                        The acts on the timeline are the evidence.
                        """)
            }
            ForEach(trace.steps) { step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(step.index + 1).")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(step.spelling)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    statusText(step.status)
                }
            }
        }
    }

    @ViewBuilder
    private func statusText(_ status: SandStepStatus) -> some View {
        switch status {
        case .pending:
            Text("pending").font(.system(size: 10)).foregroundStyle(.tertiary)
        case .acted(let name, let detail):
            Text(detail.isEmpty ? name : "\(name) \(detail)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
        case .refused(let reason):
            Text(reason)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }
}
