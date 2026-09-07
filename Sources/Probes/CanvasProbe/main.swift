//
//  main.swift
//  CanvasProbe — `mary-canvas-probe`
//
//  WHAT: Put a page on Mary's canvas without the app, and print what it said.
//  OUT:  CLI: mary-canvas-probe --html <file> [--title T] [--panel]
//             [--seconds N] [--watch] [--dry-run]
//  PIN:  THE FIRST PROBE THAT NEEDS A WINDOW. WebKit draws on the main run
//        loop, so this runs an accessory NSApplication and does its work in a
//        task that ends by terminating it. A click on the page ends it early.
//

import AppKit
import Foundation
import MaryPlugin

let usage = """
mary-canvas-probe --html <file> [--title <name>] [--panel] [--seconds <n>] [--watch]
                  [--dry-run]

  --html      the page to show, whole, read into memory
  --title     what to call it (default: the file name)
  --panel     a centred window instead of the whole screen
  --seconds   how long to leave it up (default 5); a click closes it sooner
  --watch     print the canvas's events as they happen
  --dry-run   fake windows — prints what WOULD be shown, draws nothing
"""

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }

guard let path = option("--html") else {
    print(usage)
    exit(1)
}
guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("  ✗  could not read \(path)")
    exit(1)
}
let title = option("--title") ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
let placement: CanvasPlacement = flag("--panel") ? .panel : .fullScreen
let seconds = Double(option("--seconds") ?? "") ?? 5
let dryRun = flag("--dry-run")

/// Fake windows for a dry run: every page is ready, nothing is drawn.
final class PrintingWindows: CanvasWindowing, @unchecked Sendable {
    func screenFrame() async -> CGRect? { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt {
        print("      · would prepare \(id) \"\(page.title)\" (\(page.byteCount) bytes)")
        return CanvasReceipt(id: id, ready: true)
    }
    func show(_ id: CanvasWindowID, placement: CanvasPlacement) async -> Bool {
        let frame = placement.frame(on: await screenFrame() ?? .zero)
        print("      · would show \(id) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))")
        return true
    }
    func hide(_ id: CanvasWindowID) async { print("      · would hide \(id)") }
    func close(_ id: CanvasWindowID) async { print("      · would close \(id)") }
    func closeAll() async { print("      · would close all") }
}

let service = dryRun
    ? CanvasService(seams: .init(windows: PrintingWindows()))
    : CanvasService.live

/// Runs the probe's work on the accessory app, then terminates it.
@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        if flag("--watch") {
            let events = await service.events()
            Task {
                for await event in events { print("  event  \(event)") }
            }
        }
        print("\nthe page")
        print(String(repeating: "─", count: 30))
        print("  \(title): \(html.utf8.count) bytes, \(placement == .panel ? "panel" : "full screen")")
        let started = Date()
        var dismissedByHand = false
        let result = await service.present(
            CanvasPage(title: title, html: html), placement: placement,
            onDismiss: { _, by in
                if by == .click { dismissedByHand = true }
            })
        switch result {
        case .failure(let refusal):
            print("  ✗  \(refusal.summary)")
            app.terminate(nil)
        case .success(let receipt):
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            print("  \(receipt.ready ? "✓" : "✗")  ready=\(receipt.ready)"
                + (receipt.timedOut ? " (the page never reported)" : "")
                + (receipt.log.map { " log: \($0)" } ?? "")
                + " · \(waited)ms")
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, await !service.snapshot().windows.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if dismissedByHand {
                print("  ·  closed by a click")
            } else {
                await service.dismissAll()
                print("  ·  closed after \(Int(seconds))s")
            }
            let snapshot = await service.snapshot()
            print("  ·  stage \(snapshot.holdsStage ? "still held" : "released")")
            app.terminate(nil)
        }
    }
    app.run()
}

MainActor.assumeIsolated { run() }
