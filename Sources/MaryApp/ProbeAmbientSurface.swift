//
//  ProbeAmbientSurface.swift
//  Mary
//
//  WHAT: Tier-0 screen → AmbientContextStore → prompt line (real observer).
//  OUT:  stdout. CLI: swift run Mary --probe-ambient-surface [--polls N] [--interval S]
//  PIN:  Switch apps while it polls; frontmost is the subject.
//

import AppKit
import ApplicationServices
import MaryAmbient
import MaryPlugin
import Foundation

enum ProbeAmbientSurface {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-ambient-surface")
    }

    static func start() {
        Task { @MainActor in
            let arguments = CommandLine.arguments
            let polls = value(after: "--polls", in: arguments).flatMap(Int.init) ?? 3
            let interval = value(after: "--interval", in: arguments)
                .flatMap(Double.init) ?? 3

            print("=== ambient surface probe ===")
            guard AXIsProcessTrusted() else {
                print("Accessibility is NOT trusted for this process.")
                print("Grant it to whatever Mary runs FROM (your terminal or IDE in dev),")
                print("then run again — the observer refuses to read without it.")
                exit(1)
            }
            print("Accessibility: trusted")

            let store = AmbientContextStore.shared
            let observer = AmbientSurfaceObserver()

            for poll in 1...max(1, polls) {
                if poll > 1 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                let front = NSWorkspace.shared.frontmostApplication
                let name = front?.localizedName ?? "—"
                let bundleID = front?.bundleIdentifier ?? "—"
                print("\n— poll \(poll) — frontmost: \(name) (\(bundleID))")

                guard let target = observer.target() else {
                    // A refusal is an ANSWER here, and naming which rung
                    // refused is the whole point of printing it.
                    print("  target: refused (Mary itself, or excluded system chrome)")
                    continue
                }
                print("  place: \(target.place.token)"
                    + (target.place.application.map { " (application: \($0))" } ?? ""))

                let started = ContinuousClock().now
                observer.pollOnce()
                let cost = ContinuousClock().now - started

                guard let surface = store.surface(place: target.place) else {
                    print("  surface: NONE — the walk answered nothing for this pid")
                    continue
                }
                print("  walk+publish: \(format(cost))")
                print("  window: \(surface.activeWindow?.title ?? "—")"
                    + "  (\(surface.windowCount) windows, "
                    + "\(surface.minimizedCount) minimized)")
                print("  elements: \(surface.elements.count)"
                    + "   focused: \(surface.focused?.descriptor ?? "—")")
                if surface.pageNotYetRead {
                    print("  page: hosted web content NOT YET READ (never 'empty')")
                }
                print("  fresh for: \(Int(surface.freshFor))s")
                print("  LINE (what the prompt and the pane both render):")
                print("    \(surface.surfaceLine())")

                // Addressing record — same `AmbientBridge.record` as the JSON button.
                if let context = AXEngine.ambientContext(pid: target.pid) {
                    let window = context.activeWindow?.frame
                    if let focused = context.focused {
                        print("  RECORD (focused element):")
                        if let element = context.elements.first(where: { $0.id == focused.id }) {
                            printRecord(element, window: window, capturedAt: context.capture.capturedAt)
                        } else {
                            print("    (focused element carries no roster entry to address)")
                        }
                    }
                    if let first = context.elements.first {
                        print("  RECORD (roster #1):")
                        printRecord(first, window: window, capturedAt: context.capture.capturedAt)
                    }
                }

                if AmbientPlaceResolver.isBrowser(bundleID: target.bundleID) {
                    print("  affordances: not published here — the browser lane")
                    print("               publishes its own slate from the page")
                } else {
                    // A second walk, for DISPLAY only: the slate the poll
                    // above already published is inside the index, and
                    // printing it means re-deriving what went in.
                    let affordances = AXEngine.ambientContext(pid: target.pid)
                        .map(AmbientBridge.affordances(from:)) ?? []
                    print("  affordances: \(affordances.count) published to "
                        + "\(AmbientElementScope.affordances(in: target.place).key)")
                    for affordance in affordances.prefix(8) {
                        print("    \(affordance.ordinal) · \(affordance.roleWord) · "
                            + "\(clip(affordance.label))"
                            + (affordance.isEnabled ? "" : "  [disabled]"))
                    }
                    if affordances.count > 8 {
                        print("    … \(affordances.count - 8) more")
                    }
                }
            }

            print("\n— store, all fresh lanes —")
            let surfaces = store.surfaces()
            if surfaces.isEmpty {
                print("  (none held)")
            }
            for surface in surfaces {
                print("  \(surface.place.token): \(surface.surfaceLine())")
            }
            exit(0)
        }
        // The task above needs a live run loop to get anywhere — the probe
        // family's shape, and `exit(0)` inside it is what ends the process.
        RunLoop.main.run()
    }

    private static func printRecord(
        _ element: AXScreenElement, window: CGRect?, capturedAt: Date
    ) {
        let record = AmbientBridge.record(from: element, window: window, capturedAt: capturedAt)
        guard let json = AXFrameProjection.json(record) else {
            print("    (encoding failed)")
            return
        }
        for line in json.split(separator: "\n", omittingEmptySubsequences: false) {
            print("    \(line)")
        }
    }

    private static func clip(_ text: String, limit: Int = 60) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: "⏎")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.0fms", Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1000)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
