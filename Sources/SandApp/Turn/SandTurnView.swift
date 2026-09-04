//
//  SandTurnView.swift
//  Sand
//
//  WHAT: A turn, from the words to the acts.
//  IN:   SandTurnHost
//  OUT:  route, roster trace, the model's round, the reply
//  PIN:  THE ROSTER PANE IS THE ANSWER TO "WHY WASN'T IT OFFERED". Every skill
//        appears with the disposition the arbitrator gave it and the sentence
//        it gave as the reason — "does not match this turn's embedding roster"
//        is a verdict about these words, not a defect, and seeing the same
//        skill selected under a different sentence is the whole lesson.
//
import MaryAmbient
import MaryBrain
import MaryFoundation
import SwiftUI

struct SandTurnView: View {
    @ObservedObject var host: SandTurnHost
    @ObservedObject var runtimeHost: SandRuntimeHost
    @State private var utterance = ""
    @State private var chosenSkill: String?
    @State private var arguments: [String: String] = [:]
    @State private var replyText = ""
    @State private var showsIneligible = false

    /// `--say` fires once, after the graph has loaded. Guarded so a re-render
    /// never re-asks.
    @State private var autoRan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            askRow
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let round = host.round {
                        modelRound(round)
                        Divider()
                    }
                    routeSection
                    rosterSection
                    storySection
                }
                .padding(12)
            }
        }
        .onAppear { sayIfAsked() }
        .onChange(of: runtimeHost.packages.count) { _, _ in sayIfAsked() }
        .onChange(of: host.round?.id) { _, _ in answerIfAsked() }
    }

    private func sayIfAsked() {
        guard !autoRan, let wanted = SandLaunchOptions.current.say,
              !runtimeHost.packages.isEmpty
        else { return }
        autoRan = true
        utterance = wanted
        host.run(wanted)
    }

    /// `--auto`: answer as the model would, with the roster's first offer.
    private func answerIfAsked() {
        guard SandLaunchOptions.current.auto,
              let round = host.round, let first = round.skills.first
        else { return }
        host.answer(.invoke(name: first.name, argumentsJSON: "{}"))
    }

    // MARK: - Asking

    private var askRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Say something to Mary…", text: $utterance)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { run() }
                Button(host.isRunning ? "Running…" : "Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.isRunning || utterance.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                Button("Stop") { host.cancel() }
                    .disabled(!host.isRunning)
            }
            HStack(spacing: 10) {
                Text("routing: \(host.engineWord)")
                Text("habits: in-memory")
                Spacer()
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private func run() {
        chosenSkill = nil
        arguments = [:]
        replyText = ""
        host.run(utterance)
    }

    // MARK: - The model's seat

    @ViewBuilder
    private func modelRound(_ round: SandModelRound) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Round \(round.index) — you are the model")
                    .font(.caption.bold())
                Spacer()
                Text("\(round.skills.count) skills offered")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("System prompt and history") {
                ScrollView {
                    Text(round.system + "\n\n" + round.history
                        .map { "[\($0.role)] \($0.text)" }.joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            .font(.system(size: 10))

            ForEach(round.skills, id: \.name) { schema in
                offeredRow(schema)
            }

            if let chosen = chosenSkill,
               let schema = round.skills.first(where: { $0.name == chosen }) {
                ForEach(schema.parameters, id: \.name) { parameter in
                    argumentField(parameter)
                }
                Button("Invoke as the model") {
                    host.answer(.invoke(
                        name: chosen,
                        argumentsJSON: SandRuntimeHost.argumentsJSON(arguments)))
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 6) {
                TextField("…or reply with words", text: $replyText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("Reply") { host.answer(.say(replyText)) }
                    .disabled(replyText.isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
    }

    private func offeredRow(_ schema: ModelSkillSchema) -> some View {
        Button {
            chosenSkill = schema.name
            arguments = [:]
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(schema.name)
                    .font(.system(size: 11, design: .monospaced))
                    .fontWeight(chosenSkill == schema.name ? .bold : .regular)
                Text(schema.description)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2).padding(.horizontal, 5)
            .contentShape(Rectangle())
            .background(
                chosenSkill == schema.name
                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.20))
                    : nil)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func argumentField(_ parameter: ModelSkillSchema.Parameter) -> some View {
        HStack {
            Text(parameter.name + (parameter.required ? " *" : ""))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            if let options = parameter.enumValues, !options.isEmpty {
                Picker("", selection: Binding(
                    get: { arguments[parameter.name] ?? "" },
                    set: { arguments[parameter.name] = $0 })) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(parameter.description, text: Binding(
                    get: { arguments[parameter.name] ?? "" },
                    set: { arguments[parameter.name] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - Route

    @ViewBuilder
    private var routeSection: some View {
        if let route = host.route {
            VStack(alignment: .leading, spacing: 2) {
                Text("Route").font(.caption.bold())
                row("intent", route.intent.rawValue)
                row("lead application", route.leadApplicationID ?? "—")
                row("lead place", route.leadPlace?.token ?? "—")
                if !route.gate.applications.isEmpty {
                    row("named applications", route.gate.applications.joined(separator: ", "))
                }
                if !route.gate.requestedAbilities.isEmpty {
                    row("requested abilities", route.gate.requestedAbilities
                        .map(\.rawValue).sorted().joined(separator: ", "))
                }
                row("selection defines turn", route.selectionDefinesTurn ? "yes" : "no")
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    // MARK: - Roster

    @ViewBuilder
    private var rosterSection: some View {
        let decisions = host.trace.decisions
        if !decisions.isEmpty {
            let selected = decisions.filter { $0.disposition == .selected }
            let rest = decisions.filter { $0.disposition != .selected }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Roster").font(.caption.bold())
                    Spacer()
                    Text("\(selected.count) selected of \(decisions.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(selected) { decisionRow($0) }
                if !rest.isEmpty {
                    Button {
                        showsIneligible.toggle()
                    } label: {
                        Text(showsIneligible
                             ? "hide the \(rest.count) not offered"
                             : "show the \(rest.count) not offered")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    if showsIneligible {
                        ForEach(rest) { decisionRow($0) }
                    }
                }
            }
        }
    }

    private func decisionRow(_ decision: AbilityRosterDecision) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(decision.disposition == .selected ? "●" : "○")
                .foregroundStyle(decision.disposition == .selected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(decision.reference.invocationName)
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Text("\(decision.evidence.total)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(decision.disposition.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(decision.disposition == .selected ? .green : .secondary)
                }
                Text(decision.reason)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - The story

    @ViewBuilder
    private var storySection: some View {
        if !host.entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Turn").font(.caption.bold())
                ForEach(host.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SandTurnEntry) -> some View {
        switch entry.kind {
        case .began(let utterance):
            Text("“\(utterance)”").font(.system(size: 11, weight: .bold))
        case .invocation(let name, let argumentsJSON, let runID):
            Text("dispatch \(name) \(argumentsJSON)  ·  run \(runID.prefix(8))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.blue)
        case .result(let summary, let ok):
            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(ok ? Color.green : Color.red)
        case .spoke(let text):
            Text("Mary: \(text)").font(.system(size: 11))
        case .note(let text):
            Text(text).font(.system(size: 10)).foregroundStyle(.orange)
        case .failed(let text):
            Text(text).font(.system(size: 10)).foregroundStyle(.red)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
