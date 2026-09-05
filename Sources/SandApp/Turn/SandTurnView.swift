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
//        WITH THE NUMBER THE FLOOR WAS COMPARED AGAINST. A sentence alone cannot
//        be tuned: 0.61 and 0.20 read identically as "does not match" and are
//        completely different problems — one is a fixture away, the other is the
//        wrong skill. The Election and Lane panes beside it answer the other two
//        questions a person asks in that order: was its whole Ability struck out
//        before the roster was read, and did the turn act without asking anyone.
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
    /// The utterance this roster belongs to, so a fixture kept from a row
    /// records what was actually said rather than whatever is in the field now.
    @State private var rosterUtterance = ""
    @State private var keptWord: String?

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
                    semanticSection
                    electionSection
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
        // A TRIP IS A WHOLE JOURNEY, NOT ONE SENTENCE. It drives the same host
        // this pane drives, leg by leg, and answers its own rounds — so `--say`
        // and `--auto` stay out of its way.
        if !autoRan, SandLaunchOptions.current.trip != nil,
           !runtimeHost.packages.isEmpty {
            autoRan = true
            SandTripRunner.runIfAsked(host: host, runtimeHost: runtimeHost)
            return
        }
        guard !autoRan, let wanted = SandLaunchOptions.current.say,
              !runtimeHost.packages.isEmpty
        else { return }
        autoRan = true
        utterance = wanted
        rosterUtterance = wanted
        keptWord = nil
        host.run(wanted)
    }

    /// `--auto`: answer as the model would, with the roster's first offer it can answer.
    ///
    /// PIN: `--arg` REACHES THIS LANE TOO, filtered to what the chosen skill actually
    /// declares. Sending a name the schema does not carry is how a scripted turn ends in
    /// an argument refusal that has nothing to do with what was being tested — and a
    /// turn that needs a query ("search for X") could not be scripted at all without it.
    /// AND A REQUIRED ARGUMENT NOBODY SUPPLIED IS NOT AN ANSWER. Invoking anyway is how the
    /// bench dispatched `act_on_screen {}` and read the binding's "what would you like me
    /// to do?" as a permission failure. The first offer whose required parameters are all
    /// in hand answers; when none is, the round stays parked and the story says why.
    private func answerIfAsked() {
        guard SandLaunchOptions.current.trip == nil else { return }
        guard SandLaunchOptions.current.auto, let round = host.round else { return }
        let supplied = SandLaunchOptions.current.arguments
        guard let chosen = round.skills.first(where: {
            Self.requiredArgumentsSatisfied($0, by: supplied)
        }) else {
            host.note("--auto: no offered skill has every required argument in --arg — not invoking")
            return
        }
        let declared = Set(chosen.parameters.map(\.name))
        host.answer(.invoke(
            name: chosen.name,
            argumentsJSON: SandRuntimeHost.argumentsJSON(
                supplied.filter { declared.contains($0.key) })))
    }

    /// Every required parameter present and non-blank — the one rule both the Invoke
    /// button and `--auto` read, so a scripted turn and a hand-driven one refuse the same
    /// incomplete call.
    static func requiredArgumentsSatisfied(
        _ schema: ModelSkillSchema, by arguments: [String: String]
    ) -> Bool {
        schema.parameters.filter(\.required).allSatisfy { parameter in
            !(arguments[parameter.name] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
        rosterUtterance = utterance
        keptWord = nil
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
                // A required field left blank is dropped by `argumentsJSON`, and the
                // binding then asks for it — so the button waits until it is filled.
                .disabled(!Self.requiredArgumentsSatisfied(schema, by: arguments))
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
                if let keptWord {
                    Text(keptWord)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
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
                    // THE AFFINITY, WHEREVER IT SITS. Below the floor is where a
                    // corpus problem actually shows itself, and that is exactly
                    // the row the old pane could say nothing numeric about.
                    if let affinity = decision.affinity {
                        let floor = host.trace.semantic?.floor ?? 0.62
                        Text(String(format: "%.2f", affinity))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(affinity >= floor ? Color.primary : Color.secondary)
                        if affinity < floor {
                            Text("below floor")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(decision.disposition.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(decision.disposition == .selected ? .green : .secondary)
                }
                Text(decision.reason)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            // THE REPAIR, WHERE THE PROBLEM IS VISIBLE. A row that should have
            // answered and did not is exactly the sentence its package is
            // missing — see `SandTurnHost.keepAsFixture`.
            Button("keep") {
                keptWord = host.keepAsFixture(
                    utterance: rosterUtterance,
                    decision: decision,
                    targetClass: runtimeHost.stageTargetClass)
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(.blue)
            .disabled(rosterUtterance.isEmpty)
            .help("Record this sentence as a route fixture naming this skill.")
        }
    }

    // MARK: - What the words were judged to mean

    @ViewBuilder
    private var semanticSection: some View {
        if let semantic = host.trace.semantic {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Read").font(.caption.bold())
                    Spacer()
                    Text(String(
                        format: "floor %.2f · margin %.2f", semantic.floor, semantic.margin))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                row("intent", semantic.promotedByUniqueSkill
                    ? "\(semantic.intent ?? "—") (promoted by a unique skill)"
                    : String(format: "%@  %.2f  runner-up %@",
                             semantic.intent ?? "—", semantic.intentScore,
                             semantic.intentRunnerUp ?? "none"))
                row("unique winner", semantic.uniqueSkill ?? "none — no skill cleared the margin")
                if let lane = semantic.lane { laneRow(lane) }
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    /// WHICH LANE ANSWERED, and for the shortcut, how the words became arguments.
    /// A no-model dispatch is the hardest lane to trust on sight — the peeling is
    /// the only evidence it filled the right thing.
    @ViewBuilder
    private func laneRow(_ lane: SemanticTurnLane) -> some View {
        switch lane {
        case let .confidence(name, argumentsJSON, stages):
            row("lane", "confidence — no model round")
            row("dispatched", "\(name) \(argumentsJSON)")
            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                row("", stage)
            }
        case .model:
            row("lane", "model")
        case let .affordance(labels, score):
            row("lane", String(
                format: "affordance %.2f — %@", score, labels.joined(separator: ", ")))
        }
    }

    // MARK: - The Ability election

    /// WHICH ABILITIES EVEN STOOD. An Ability that loses its conflict group takes
    /// every one of its Skills out of the roster before a single one is weighed,
    /// and until this pane existed the only trace of that was the same borrowed
    /// sentence repeated on each of them.
    @ViewBuilder
    private var electionSection: some View {
        let rows = host.trace.election
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Election").font(.caption.bold())
                    Spacer()
                    Text(rows.first?.regime.rawValue ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                ForEach(rows) { election in
                    HStack(alignment: .top, spacing: 6) {
                        Text(election.isActive ? "●" : "○")
                            .foregroundStyle(election.isActive ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(election.abilityID.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                Spacer()
                                if let best = election.bestMemberAffinity {
                                    Text(String(format: "best %.2f", best))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Text("predicate \(election.predicateScore)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(election.reason)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
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
