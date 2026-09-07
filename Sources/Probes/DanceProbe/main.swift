//
//  main.swift
//  DanceProbe — `mary-dance-probe`
//
//  WHAT: Drive the dance without the app: a shader from a file, or a
//        scripted composer, through the real canvas or a printing one.
//  OUT:  CLI: mary-dance-probe --shader <file> [--seconds N] [--mood]
//             mary-dance-probe --dance | --mood [--shader <file>] [--watch] [--dry-run]
//  PIN:  NO MODEL HERE. The probe's composer is the file it was given; the
//        real composer is the brain's and needs the app. What this proves is
//        everything after composition: admission, rehearsal, the beat, the
//        tidy-up — the parts a bad shader or a slow window would break.
//

import AppKit
import Foundation
import MaryBrain
import MaryPlugin
import MaryRuntime

let usage = """
mary-dance-probe (--shader <file.glsl> | --seer) [--mood] [--seconds <n>] [--watch] [--dry-run]

  --shader    a fragment shader (bare, or a composer's reply with a fence)
  --seer      compose through Seer instead — the real composer, the whole troupe
  --mood      hold it as one still window instead of dancing (closes after --seconds, default 8)
  --seconds   with --mood, how long to hold it; a dance is always 15 s
  --watch     print the engine's and the canvas's events as they happen
  --dry-run   fake windows — prints the beat, draws nothing
"""

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }

let useSeer = flag("--seer")
let path = option("--shader") ?? ""
let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
guard useSeer || !source.isEmpty else {
    print(usage)
    exit(1)
}
let mood = flag("--mood")
let seconds = Double(option("--seconds") ?? "") ?? 8
let dryRun = flag("--dry-run")
let watching = flag("--watch")

/// The file, as a composer.
struct FileComposer: DanceComposing {
    let source: String
    let name: String
    func isReady() async -> Bool { true }
    func compose(_ brief: DanceBrief) async throws -> DanceComposition {
        if let repair = brief.repair {
            print("  ✗  the engine asked for a repair: \(repair.problem)")
            print("     (a file cannot be repaired — the same shader goes back)")
        }
        return DanceComposition(feeling: "From \(name).", glsl: source)
    }
}

/// Fake windows for a dry run: every page is ready, nothing is drawn.
final class PrintingWindows: CanvasWindowing, @unchecked Sendable {
    func screenFrame() async -> CGRect? { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt {
        print("      · prepared \(id) \"\(page.title)\" (\(page.byteCount) bytes)")
        return CanvasReceipt(id: id, ready: true)
    }
    func show(_ id: CanvasWindowID, placement: CanvasPlacement) async -> Bool {
        let frame = placement.frame(on: await screenFrame() ?? .zero)
        print("      · show \(id) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))")
        return true
    }
    func hide(_ id: CanvasWindowID) async { print("      · hide \(id)") }
    func close(_ id: CanvasWindowID) async { print("      · close \(id)") }
    func closeAll() async { print("      · close all") }
}

let canvas = dryRun ? CanvasService(seams: .init(windows: PrintingWindows())) : CanvasService.live

/// The real composer, over the same stack and sign-in the app's probe uses.
func seerComposer() async -> (any DanceComposing)? {
    DotEnv.loadMaryEnvironment()
    let defaults = ConfigService.Center.State()
    let nodeID = TotemNodeIdentity.adoptOrMint(configured: defaults.totemNodeID)
    await MaryRuntime.applyServers(config: defaults, nodeID: nodeID)
    print("  [stack] bringing servers up…")
    if let failure = await MaryRuntime.localStack.ensureRunning() {
        print("  ✗  stack: \(failure)")
        return nil
    }
    if let error = await MaryRuntime.applySeerAccount(
        email: defaults.seerEmail, password: defaults.seerPassword, seerPort: defaults.seerPort) {
        print("  ✗  auth: \(error)")
        return nil
    }
    await MaryRuntime.installBrainConfiguration(projects: [:])
    await MaryRuntime.connectSeerToBrain(chat: true, archiving: false, stackEnabled: true)
    if let error = await MaryRuntime.applyEngine(
        .mistral, skillEngine: .mistral, seerEnabled: true, progress: { _ in }) {
        print("  ✗  engine: \(error)")
        return nil
    }
    print("  [seer] signed in; composing through mistral")
    return SeerShaderComposer(complete: MaryRuntime.studioComplete)
}

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        if watching {
            let canvasEvents = await canvas.events()
            Task { for await event in canvasEvents { print("  canvas  \(event)") } }
        }
        let composer: any DanceComposing
        if useSeer {
            heading("the composer")
            guard let seer = await seerComposer() else { app.terminate(nil); return }
            composer = seer
        } else {
            heading("the shader")
            switch GLSLFragment.admit(source) {
            case .failure(let refusal):
                print("  ✗  not admitted: \(refusal.summary)")
                print("     the engine will ask for a repair and refuse; watch it do so")
            case .success(let fragment):
                print("  ✓  admitted: \(fragment.source.split(separator: "\n").count) lines")
            }
            composer = FileComposer(source: source, name: URL(fileURLWithPath: path).lastPathComponent)
        }
        let engine = DanceEngine(seams: .init(canvas: canvas, compose: composer))
        if watching {
            let danceEvents = await engine.events()
            Task { for await event in danceEvents { print("  dance   \(event)") } }
        }

        heading(mood ? "the mood" : "the dance")
        let started = Date()
        let brief = DanceBrief(subject: mood ? .mary : .dance, utterance: mood ? "How are you feeling?" : "Let's dance.")
        let outcome = mood ? await engine.mood(brief) : await engine.dance(brief)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome {
        case .refused(let refusal):
            print("  ✗  \(refusal.summary) · \(elapsed)ms")
            app.terminate(nil)
        case .started(let feeling):
            print("  ✓  started — \"\(feeling)\" · first window in \(elapsed)ms")
            let deadline = Date().addingTimeInterval(mood ? seconds : 20)
            while Date() < deadline {
                let snapshot = await engine.snapshot()
                if snapshot.phase == .idle { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let snapshot = await engine.snapshot()
            if snapshot.phase != .idle {
                await engine.stop()
                print("  ·  stopped after \(Int(seconds))s")
            }
            let final = await engine.snapshot()
            print("  ·  phase \(final.phase.rawValue) · \(final.beats) beats · windows left \(final.windows.count)")
            let stage = await canvas.snapshot()
            print("  ·  stage \(stage.holdsStage ? "still held" : "released") · canvas windows \(stage.windows.count)")
            app.terminate(nil)
        }
    }
    app.run()
}

MainActor.assumeIsolated { run() }
