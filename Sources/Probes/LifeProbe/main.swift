//
//  main.swift
//  LifeProbe — `mary-life-probe`
//
//  WHAT: What the idle engine sees, decides, and holds — without the app.
//  OUT:  CLI: mary-life-probe [--node <uuid>] [--port 9093] [--watch]
//  PIN:  DRY BY DEFAULT. This probe never lets the engine dispatch; watching
//        an engine must not be a way to make it act.
//

import Foundation
import MaryBrain
import MaryFoundation
import MaryRuntime

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

func row(_ label: String, _ value: String) {
    let padded = label.padding(toLength: max(22, label.count), withPad: " ", startingAt: 0)
    print("  \(padded)\(value)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}

let watching = arguments.contains("--watch")
let nodeID = option("--node") ?? ProcessInfo.processInfo.environment["MARY_TOTEM_NODE_ID"] ?? ""
let port = Int(option("--port") ?? "") ?? ServerSpec.Defaults.fleetGRPCPort

MaryRuntime.configureLifeAccess(nodeID: nodeID, fleetGRPCPort: port)

heading("dial")
row("totem node", nodeID.isEmpty ? "— (pass --node <uuid>)" : nodeID)
row("fleet gRPC", "127.0.0.1:\(port)")

heading("the machine")
let idle = LifeConditionsProvider.secondsSinceUserInput()
row("seconds since input", idle.map { String(format: "%.0fs", $0) } ?? "unavailable")

let conditions = await LifeConditionsProvider().conditions()
row("turn in flight", conditions.isTurnInFlight ? "yes" : "no")
row("skill running", conditions.isSkillRunning ? "yes" : "no")
row("workspace indexing", conditions.isWorkspaceIndexing ? "yes" : "no")

heading("adapters")
let adapters = await MaryRuntime.lifeSlots.adapters()
row("fleet reachable", adapters.reachable ? "yes" : "no")
if adapters.slots.isEmpty {
    print("  · none published for this node")
}
for (id, slot) in adapters.slots.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    let state = slot.training ? "training" : (slot.ready ? "ready" : "not ready")
    row(
        id.rawValue,
        "gen \(slot.generation) · \(slot.pairCount) pairs · \(state) · \(String(slot.cid.prefix(8)))")
    if !slot.modelID.isEmpty { row("", slot.modelID) }
}

heading("the world")
if let world = await LifeWorldProvider().pulseWorld() {
    row("lead", world.leadLabel)
    row(
        "lead disciplines",
        world.leadDisciplines.isEmpty
            ? "none declared" : world.leadDisciplines.map(\.rawValue).joined(separator: ", "))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(world.input),
       let text = String(data: data, encoding: .utf8)
    {
        print("\n  input the adapter would see:")
        for line in text.split(separator: "\n") { print("    \(line)") }
    }
} else {
    print("  · nothing is in front")
}

heading("one pulse (dry run)")
// Arm observe WITHOUT starting the loop: a probe that started the timer
// would race its own pulse against the loop's first one and report whichever
// lost. Observe dispatches nothing; `dryRun` guarantees it a second time.
await MaryRuntime.armLifeMode(.observe)
let decision = await MaryRuntime.lifePulseNow(dryRun: true)
row("outcome", decision.outcome.rawValue)
if let skip = decision.skip { row("skipped because", "\(skip.rawValue) — \(decision.detail)") }
if let discipline = decision.discipline { row("discipline", discipline.rawValue) }
if let adapter = decision.adapter {
    row("adapter", "gen \(adapter.generation) · \(adapter.shortCID) · \(adapter.modelID)")
}
if decision.inferenceMs > 0 { row("inference", "\(decision.inferenceMs)ms") }
if decision.promptTokens > 0 {
    row("prompt tokens", "\(decision.promptTokens)")
    row("tokens forced", String(format: "%.0f%%", decision.forcedFraction * 100))
}
if let output = decision.output {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(output),
       let text = String(data: data, encoding: .utf8)
    {
        print("\n  what it would do:")
        for line in text.split(separator: "\n") { print("    \(line)") }
    }
}

let snapshot = await MaryRuntime.lifeEngineSnapshot()
heading("engine")
row("mode", snapshot.mode.rawValue)
row("phase", snapshot.phaseDetail.isEmpty
    ? snapshot.phase.rawValue : "\(snapshot.phase.rawValue) · \(snapshot.phaseDetail)")
row("adapters ready", "\(snapshot.readyCount) of \(snapshot.adapters.count)")
row("decisions kept", "\(snapshot.recent.count)")
for failure in snapshot.errorTail.prefix(3) { row("error", failure) }

if watching {
    heading("watching (ctrl-c to stop)")
    for await event in await MaryRuntime.lifeEngineEvents() {
        switch event {
        case .phaseChanged(let phase, let detail):
            print("  phase   \(phase.rawValue)\(detail.isEmpty ? "" : " · \(detail)")")
        case .decision(let decision):
            print("  decide  \(decision.line)")
        case .adaptersChanged(let refs):
            print("  slots   \(refs.count) adapter\(refs.count == 1 ? "" : "s")")
        case .adapterLoaded(let ref):
            print("  load    \(ref.abilityID.rawValue) gen \(ref.generation)")
        case .adapterUnloaded(let cid):
            print("  unload  \(String(cid.prefix(8)))")
        case .modeChanged(let mode):
            print("  mode    \(mode.rawValue)")
        case .failed(let detail):
            print("  error   \(detail)")
        }
    }
} else {
    print("")
}
