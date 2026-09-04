//
//  main.swift
//  WebProbe — `mary-web-probe`
//
//  WHAT: The browser lane against a live browser: shell by Accessibility, page by
//        sight, playback driven and PUT BACK.
//  OUT:  CLI: mary-web-probe [--browser safari|chrome] [--perceive]
//             [--media toggle|play|pause|mute|unmute|fullscreen|seek=0.5] [--open URL]
//             [--dry-run] [--watch] [--save <path.png>] [--settle ms] [--hover-at x,y]
//        The shell read always runs — it is what everything else is aimed with.
//  PIN:  Run signed (scripts/dev.sh or sign-binary.sh); an ad-hoc build loses both the
//        Accessibility and the Screen Recording grant, and a lane that cannot see looks
//        exactly like a lane that found nothing.
//        `--media` PUTS PLAYBACK BACK, the same courtesy mary-media-probe pays the
//        transport: a diagnostic that leaves someone's video paused is a bug report
//        waiting to be filed against the wrong thing.
//

import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
import Foundation
import MaryAmbient
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin

var failures = 0
func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}
func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

let arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}

guard AXIsProcessTrusted() else {
    print("""
    Accessibility is not granted for this binary.

    System Settings → Privacy & Security → Accessibility, then add the binary this ran
    from. If it worked before and stopped, the build was signed ad-hoc: run
    ./scripts/sign-binary.sh .build/debug/mary-web-probe, which uses the same stable
    identity as dev.sh so one grant survives rebuilds.
    """)
    exit(1)
}

// MARK: - The graph

heading("the roster")

let adapters = MaryAdapterCatalog.adapters()
let load = AbilityLibrary.shared.configureAndLoad(
    adapterManifests: MaryAdapterCatalog.adapterManifests(
        adapters: adapters, observers: MaryAdapterCatalog.observers()),
    nativeApplicationProfiles: adapters.map(\.applicationProfile),
    primitiveBindings: [])
check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
for issue in load.issues where issue.severity == .error {
    print("      ! \(issue.code): \(issue.message)")
}

// THE SKILLS THE MODEL WOULD BE OFFERED. Graph validity is not availability — a skill
// can load cleanly and still be blocked on a target class nothing claims — so the
// readiness the runtime computes is the thing worth printing.
for runtime in load.snapshot.skills
where runtime.skill.id.rawValue.hasPrefix("browsing.") {
    let name = runtime.skill.modelExposure.invocationName ?? runtime.skill.id.rawValue
    check(runtime.availability.readiness == .ready,
          "\(name) is ready", "\(runtime.availability.readiness)")
}

let registrations = load.snapshot.webSurfaceRegistrations()
WebSurfaceSupport.shared.reconcile(registrations)
check(!registrations.isEmpty, "a package declares a browser",
      registrations.map(\.applicationID).sorted().joined(separator: ", "))

// MARK: - The target

guard let (registration, pid) = WebSurfaceSupport.shared.resolve(value("--browser")) else {
    let running = WebSurfaceSupport.shared.runningDisplayNames()
    print("\n  ✗  no declared browser resolved.")
    if running.count > 1 {
        print("     \(running.joined(separator: " and ")) are both running — name one with --browser.")
    } else {
        print("     Open Safari or Chrome and try again.")
    }
    exit(1)
}
let target = BrowserTarget(registration: registration, processIdentifier: pid)
check(true, "resolved a browser", "\(registration.displayName) (pid \(pid))")
check(true, "its page-content lane",
      "\(registration.host(pid: pid).rawValue) · frame from \(registration.schema.pageFrameSource.rawValue)")

let engine = BrowserEngine(dryRun: flag("--dry-run"))
if flag("--watch") {
    Task.detached {
        for await event in await engine.events() { print("      · \(event)") }
    }
}

// MARK: - The shell

heading("the shell, through accessibility")

let shellOutcome = await engine.readShell(target)
guard let shell = shellOutcome.shell else {
    check(false, "the window was readable", shellOutcome.spoken)
    exit(1)
}
check(true, "the window was readable", shell.title ?? "untitled")
// THE URL IS HELD, NEVER SPOKEN — the probe prints the SITE, the same as a turn would.
check(shell.siteName != nil, "the site was named", shell.siteName ?? "no address")
check(shell.pageFrame != nil, "the page was located",
      shell.pageFrame.map { "\(Int($0.width))×\(Int($0.height)) via \(shell.pageFrameSource)" }
        ?? "no frame")
check(shell.windowID != nil, "the window has a capture id",
      shell.windowID.map(String.init) ?? "none — capture will pair by geometry")
print("      · history: back \(shell.canGoBack.map(String.init) ?? "unreadable")"
      + " · forward \(shell.canGoForward.map(String.init) ?? "unreadable")")
print("      · tabs: \(shell.tabs.isEmpty ? "none published" : "\(shell.tabs.count)")")
for tab in shell.tabs.prefix(4) { print("        – \(tab)") }
print("\n      \(shellOutcome.spoken)")

// MARK: - The pixels themselves

// `--save` writes the exact crop the page lane reads, so a detector can be tuned
// against a real capture offline instead of by driving a browser by hand.
if let path = value("--save"), let pageFrame = shell.pageFrame {
    heading("the capture")
    // The same staging AND reveal the engine performs, so the saved crop is the one it
    // reads — an inactive window shows no transport at all.
    let forward = await LiveBrowserStaging().bringForward(pid: pid)
    check(forward, "the window came forward",
          NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing frontmost")

    await LiveBrowserHands().reveal(over: pageFrame, pid: pid)
    // The same settle the engine allows, unless the caller is measuring that.
    try? await Task.sleep(for: .milliseconds(value("--settle").flatMap(Int.init) ?? 400))
    do {
        let captured = try await WindowPixels.capture(pid: pid, windowID: shell.windowID)
        guard let cropped = WindowPixels.crop(captured, to: pageFrame) else {
            check(false, "the page was cropped out of the window")
            exit(1)
        }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
            check(false, "the file could not be created", path)
            exit(1)
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        check(CGImageDestinationFinalize(destination), "saved the page crop",
              "\(cropped.width)×\(cropped.height) @\(Int(captured.pixelsPerPoint))x → \(path)")
        // AND WHAT THE LANE MAKES OF THAT EXACT IMAGE. Saving one capture and reading
        // another leaves every disagreement unattributable.
        let reading = try await VisionPageReader.read(
            pid: pid, windowID: shell.windowID, pageFrame: pageFrame, intent: .media,
            appName: registration.displayName, windowTitle: shell.title ?? "")
        if let media = reading.media {
            print("      · reads as: \(media.spoken)")
            print("      · controls: \(media.others.count)"
                  + (media.progress.map { String(format: " · track at y=%.0f", $0.frame.midY) } ?? " · no track"))
            for control in media.others.prefix(8) {
                print("        – \(control.glyph.rawValue) at (\(Int(control.clickPoint.x)), \(Int(control.clickPoint.y)))")
            }
        }
    } catch {
        check(false, "the capture failed", String(describing: error))
    }
}

// MARK: - The page

if flag("--perceive") || value("--media") != nil {
    heading("the page, through vision")
    let described = await engine.describeMedia(in: target)
    if let media = described.media {
        check(media.controlsVisible, "a transport was found",
              "\(media.others.count) controls")
        check(media.progress != nil, "the progress track was measured",
              media.progress.map { String(format: "%.1f%%", $0.fraction * 100) } ?? "none")
        check(media.playback != .unknown, "playback was decided", media.playback.rawValue)
        print("      · witnesses: \(media.witnesses.joined(separator: " · "))")
        print("      · transport: \(media.playPause.map { "\($0.glyph.rawValue) at (\(Int($0.clickPoint.x)), \(Int($0.clickPoint.y)))" } ?? "not found")")
        print("      · volume:    \(media.volume.map(\.glyph.rawValue) ?? "not found")")
        print("      · fullscreen:\(media.fullscreen.map { " \($0.glyph.rawValue)" } ?? " not found")")
        if let elapsed = media.elapsed {
            print("      · clock:     \(MediaControlReading.clock(elapsed))"
                  + (media.duration.map { " of \(MediaControlReading.clock($0))" } ?? ""))
        }
        print("\n      \(media.spoken)")
    } else {
        check(false, "a transport was found", described.spoken)
    }
}

// MARK: - Driving it

if let requested = value("--media") {
    heading("the transport, driven purely from what was seen")

    let action: MediaAction?
    if requested.hasPrefix("seek=") {
        action = Double(requested.dropFirst(5)).map { MediaAction.seek(fraction: $0) }
    } else {
        switch requested {
        case "toggle": action = .toggle
        case "play": action = .play
        case "pause": action = .pause
        case "mute": action = .mute
        case "unmute": action = .unmute
        case "fullscreen": action = .fullscreen
        default: action = nil
        }
    }
    guard let action else {
        print("  ✗  unknown action \"\(requested)\" — toggle|play|pause|mute|unmute|fullscreen|seek=0.5")
        exit(1)
    }

    let before = await engine.snapshot().lastMedia
    let outcome = await engine.controlMedia(action, in: target)
    check(outcome.ok, "the act landed and was verified", outcome.spoken)
    if let refusal = outcome.refusal { print("      · refusal: \(refusal)") }

    // PUT IT BACK. Only for the reversible verbs, and only when it actually moved.
    if outcome.ok, !flag("--dry-run") {
        let reverse: MediaAction?
        switch action {
        case .toggle: reverse = .toggle
        case .play: reverse = .pause
        case .pause: reverse = .play
        case .mute: reverse = .unmute
        case .unmute: reverse = .mute
        // A seek cannot be undone without knowing where it was; say so rather than
        // guessing a position back.
        case .seek, .fullscreen: reverse = nil
        }
        if let reverse {
            let restored = await engine.controlMedia(reverse, in: target)
            check(restored.ok, "and was put back", restored.spoken)
        } else {
            print("      · not reversible — left as it is")
        }
    }
    _ = before
}

// MARK: - Hover delivery experiment

// DOES A HOVER REACH THE PAGE AT ALL. Aims at one point given in the CAPTURE's own
// coordinates and saves the result, so a control with an obvious hover state (a
// Subscribe button, a link) answers the question by changing colour or not.
if let spec = value("--hover-at"), let pageFrame = shell.pageFrame {
    heading("hover delivery")
    let parts = spec.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else {
        check(false, "--hover-at takes x,y in capture coordinates"); exit(1)
    }
    _ = await LiveBrowserStaging().bringForward(pid: pid)
    let point = CGPoint(x: pageFrame.minX + parts[0], y: pageFrame.minY + parts[1])
    PointerDriver.hover(at: point, pid: pid)
    try? await Task.sleep(for: .milliseconds(600))
    if let captured = try? await WindowPixels.capture(pid: pid, windowID: shell.windowID),
       let cropped = WindowPixels.crop(captured, to: pageFrame),
       let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ritesh-Documents-rao-repositories-Mary/ba4bc841-f15c-4595-bdbf-ccdc3e8459f9/scratchpad/hover-at.png") as CFURL,
        "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, cropped, nil)
        _ = CGImageDestinationFinalize(destination)
        check(true, "hovered and captured",
              "(\(Int(parts[0])), \(Int(parts[1]))) → hover-at.png")
    }
}

// MARK: - Navigating

if let address = value("--open") {
    heading("navigating")
    let outcome = await engine.navigate(.open(address), in: target)
    check(outcome.ok, "the page settled", outcome.spoken)
}

// MARK: - The verdict

heading("── THE ENGINE ──")
let snapshot = await engine.snapshot()
print("  acts \(snapshot.acts)   refusals \(snapshot.refusals)   perceptions \(snapshot.perceptions)")
if let refusal = snapshot.lastRefusal { print("  last refusal: \(refusal.summary)") }
// The machine layer's own tally. Rendered here rather than shared with AXProbe's
// watcher, because a probe printing four lines does not need a rendering library.
let machine = ComputerUseMonitor.shared.snapshot()
print("  machine — acts \(machine.totalActs)  refusals \(machine.totalRefusals)")
for (lane, tally) in machine.lanes.sorted(by: { $0.key.rawValue < $1.key.rawValue })
where tally.acts > 0 || tally.refusals > 0 {
    print("    \(lane.rawValue): \(tally.acts) acts, \(tally.refusals) refusals")
}
if let refusal = machine.lastRefusal {
    print("    last: \(refusal.lane.rawValue) \(refusal.name) — \(refusal.reason.summary)")
}

heading("── THE VERDICT ──")
if failures == 0 {
    print("""
      The browser's own controls came from Accessibility and the page's player came
      from pixels — no site shortcut, no media key, no scripting — and every act was
      proved by looking again.
    """)
} else {
    print("  \(failures) check(s) failed.")
}
exit(failures == 0 ? 0 : 1)
