//
//  WatchProbe.swift
//  AXProbe
//
//  WHAT: Watch the machine layer act, live.
//  OUT:  CLI: mary-ax-probe --watch [--self]
//  PIN:  THE MONITOR IS PROCESS-LOCAL. `ComputerUseMonitor.shared` remembers
//        what THIS process did, so watching the running app means reading the
//        log mirror every report site writes — `--self` watches this probe's
//        own acts instead, which is what the stream API looks like in code.
//

import Foundation
import MaryComputerUse

enum WatchProbe {

    static func shouldRun(_ arguments: [String]) -> Bool { arguments.contains("--watch") }

    static func run(_ arguments: [String]) async {
        if arguments.contains("--self") {
            await watchThisProcess()
        } else {
            watchTheApp()
        }
    }

    // MARK: - Watching the running app

    /// Tail the log mirror. Every `note` writes one public line there, which
    /// is the only way one process can watch another's hands.
    private static func watchTheApp() {
        print("""
        Watching Mary's machine layer. Act in the app — press a key chord,
        rehearse a recipe — and the acts and refusals appear below.

        Nothing appears if the app is not running, or if it was built without
        ./scripts/dev.sh (an ad-hoc identity loses the Accessibility grant, so
        the hands refuse before they ever act).

        Ctrl-C to stop.

        """)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact",
            "--predicate",
            #"subsystem == "nyc.rao.mary" AND category == "computer-use""#,
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("could not start log stream: \(error)")
        }
    }

    // MARK: - Watching this process

    /// The stream API, exercised for real: subscribe, act, print what arrives.
    private static func watchThisProcess() async {
        print("Watching this probe's own machine layer (--self).\n")
        let monitor = ComputerUseMonitor.shared
        let stream = monitor.events()

        let printer = Task {
            for await event in stream {
                switch event {
                case .snapshot(let snapshot):
                    print(render(snapshot))
                case .act(let act):
                    print("  act      #\(act.sequence) \(act.lane.rawValue)/\(act.name) \(act.detail)")
                case .refusal(let refusal):
                    print("  refused  #\(refusal.sequence) \(refusal.lane.rawValue)/\(refusal.name)"
                          + " — \(refusal.reason.summary)")
                }
            }
        }

        // A refusal this probe can always cause honestly: aim at a space
        // nothing captured. Nothing is posted, and the reason is named.
        _ = PointerDriver.resolve(
            x: 0.5, y: 0.5, space: "a-region-nobody-captured",
            spaces: .init(), pid: ProcessInfo.processInfo.processIdentifier)

        try? await Task.sleep(nanoseconds: 300_000_000)
        printer.cancel()
        print("\n\(render(monitor.snapshot()))")
    }

    // MARK: - Rendering

    static func render(_ snapshot: ComputerUseSnapshot) -> String {
        var lines = ["  ── computer use ──────────────────────────────"]
        lines.append("  accessibility  \(snapshot.accessibilityTrusted ? "granted" : "NOT GRANTED")")
        lines.append("  screen record  \(snapshot.screenRecordingGranted ? "granted" : "not granted")")
        lines.append("  acts \(snapshot.totalActs)   refusals \(snapshot.totalRefusals)")
        if snapshot.sense.walks > 0 {
            lines.append(String(
                format: "  sense          %d walks, last %d nodes in %.0f ms%@",
                snapshot.sense.walks, snapshot.sense.lastNodes,
                snapshot.sense.lastDuration * 1000,
                snapshot.sense.truncatedWalks > 0
                    ? " (\(snapshot.sense.truncatedWalks) truncated)" : ""))
        }
        for lane in ComputerUseLane.allCases {
            guard let tally = snapshot.lanes[lane], tally.acts + tally.refusals > 0 else { continue }
            lines.append("  \(lane.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                         + "\(tally.acts) acts, \(tally.refusals) refused"
                         + (tally.lastAct.map { "   last: \($0.name) \($0.detail)" } ?? ""))
        }
        if let refusal = snapshot.lastRefusal {
            lines.append("  last refusal   \(refusal.lane.rawValue)/\(refusal.name)"
                         + " — \(refusal.reason.summary)")
        }
        return lines.joined(separator: "\n")
    }
}
