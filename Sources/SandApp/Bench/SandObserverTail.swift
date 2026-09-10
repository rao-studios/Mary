//
//  SandObserverTail.swift
//  Sand
//
//  WHAT: Watch ANOTHER Mary process act — the running app, from here.
//  IN:   `log stream` over subsystem nyc.rao.mary, categories computer-use and lanes
//  OUT:  external rows on the timeline
//  PIN:  THE MONITOR IS PROCESS-LOCAL. `ComputerUseMonitor.shared` remembers
//        what ITS OWN process did, so Sand cannot subscribe to Mary's instance
//        — but every report site also writes one public line to the log, and
//        that mirror is the only way one process can watch another's hands.
//        Read-only by construction: this reads a log, and cannot influence
//        what the other process does.
//        SAND'S OWN LINES ARE DROPPED. It writes to the same mirror, and a
//        doubled act would look like two acts.
//
import Foundation

/// Tails the shared log mirror and hands each line to a sink.
@MainActor
final class SandObserverTail {

    private var process: Process?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    var isRunning: Bool { process?.isRunning ?? false }

    /// `line` is called on the main actor for each act or refusal another
    /// process reported.
    func start(_ line: @escaping @MainActor (String) -> Void) {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "ndjson",
            "--predicate",
            #"subsystem == "nyc.rao.mary" AND (category == "computer-use" OR category == "lanes")"#,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [selfPID] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(separator: "\n") {
                guard let payload = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: payload)
                        as? [String: Any],
                      let message = object["eventMessage"] as? String
                else { continue }
                // Sand writes to this mirror too. Its own acts are already on
                // the timeline from the in-process stream, in order.
                if let pid = object["processID"] as? Int, pid_t(pid) == selfPID { continue }
                let process = (object["processImagePath"] as? String)
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
                Task { @MainActor in line("\(process): \(message)") }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            Task { @MainActor in
                line("could not start log stream: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
