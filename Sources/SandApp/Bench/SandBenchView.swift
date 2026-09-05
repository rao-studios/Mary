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
    /// Lane ids the person folded away. Seeded from each lane's own default
    /// (supporting lanes start closed) the first time a package is shown.
    @State private var collapsedLanes: Set<String> = []
    @State private var seededCollapseFor: PackageID?

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
            .layoutPriority(1)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                runControls
                outcomeBanner
                stepList
            }
            .padding(12)
            Divider()
            // THE LIST IS THE LONGER OF THE TWO. A discipline like writing
            // lends thirty-one skills, and a fixed 200pt timeline left three of
            // them visible. The timeline keeps enough height to read a run and
            // yields the rest to what there is to pick from.
            SandTimelineView(trace: trace)
                .frame(minHeight: 140, maxHeight: 260)
        }
        .frame(minWidth: 380)
        .background(.background)
        .onChange(of: host.packages.count) { _, _ in runIfAsked(); seedCollapse() }
        .onChange(of: package?.id) { _, _ in seedCollapse() }
        .onAppear { runIfAsked(); seedCollapse() }
    }

    /// Fold the lanes each package says start folded, once per package.
    private func seedCollapse() {
        guard let package, seededCollapseFor != package.id else { return }
        seededCollapseFor = package.id
        collapsedLanes = Set(
            package.lanes.filter(\.isCollapsedByDefault).map(\.id))
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
            if package.lanes.isEmpty {
                Text("This package carries no recipes and realizes no skills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(package.lanes) { lane in
                    laneSection(lane)
                }
            }
        }
    }

    /// One lane: the package's own recipes, a discipline it extends, or
    /// something it optionally supports. Supporting lanes start collapsed —
    /// window management is on hand for most expertises and would otherwise be
    /// the longest list on screen.
    @ViewBuilder
    private func laneSection(_ lane: SandLane) -> some View {
        let isCollapsed = collapsedLanes.contains(lane.id)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if isCollapsed { collapsedLanes.remove(lane.id) }
                else { collapsedLanes.insert(lane.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Color.sandTint(lane.tint))
                        .frame(width: 7, height: 7)
                    Text(lane.title).font(.caption.bold())
                    Text(lane.note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(lane.runnables.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(lane.runnables) { item in
                    runnableRow(item, isSelected: item.id == runnable?.id)
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
                    readinessChip(item)
                    Text(stepsWord(item))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(item.invocation.isEmpty ? "—" : item.invocation)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.realizationWord)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if !item.natureWord.isEmpty {
                    Text(item.natureWord)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if let reason = item.unrunnableReason {
                    Text(reason)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
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

    /// Green/orange/red, with the runtime's own reasons behind it. Readiness is
    /// the difference between "this will act" and "no adapter satisfies it".
    @ViewBuilder
    private func readinessChip(_ item: SandRunnable) -> some View {
        if let readiness = item.readiness {
            let color: Color = switch readiness {
            case .ready: .green
            case .partial: .orange
            case .blocked: .red
            }
            Text(readiness.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(color)
                .help(host.availabilityReasons(forSkillNamed: item.invocation)
                        .joined(separator: "\n"))
        }
    }

    private func stepsWord(_ item: SandRunnable) -> String {
        item.steps.isEmpty ? "" : "\(item.steps.count) steps"
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
                            placeholder: parameter.description.isEmpty
                                ? parameter.type : parameter.description)
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
                // A PICKER, NOT A TEXT FIELD, wherever the roster declares the
                // values: `action` on control_playback is the difference
                // between testing "next" in one click and mistyping it.
                Picker("", selection: binding(name)) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(placeholder, text: binding(name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                // `app` LEFT EMPTY ON PURPOSE. The runtime fills it from the
                // expertise it resolves for the lead, and watching THAT is the
                // point; this button is for pinning it deliberately.
                if name == "app", let package, !package.applicationID.isEmpty {
                    Button("use \(package.applicationID)") {
                        arguments[name] = package.applicationID
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
                }
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
            Text("bypasses routing and the offer ledger — the turn lane is the honest roster")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.summary).font(.caption)
                    if !outcome.receipt.isEmpty {
                        Text(outcome.receipt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
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
        if trace.steps.isEmpty, let runnable, trace.isRunning || trace.lastOutcome != nil {
            // NO STEPS IS NOT AN EMPTY RECIPE. An adapter-realized skill has no
            // authored steps at all, and printing a blank list would read like
            // a recipe that failed to compile.
            Divider()
            Text("realized by \(runnable.realizationWord) — the acts below are its own")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
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

// MARK: - Tint

extension Color {
    /// A package's authored tint ("#8ECAE6"). Anything unparseable falls back
    /// to the accent color rather than to a wrong color that reads as authored.
    static func sandTint(_ hex: String) -> Color {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .accentColor }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
