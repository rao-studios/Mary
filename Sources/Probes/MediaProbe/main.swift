//
//  main.swift
//  MediaProbe — `mary-media-probe`
//
//  WHAT: Declared mediaSurface vs a running player's Accessibility tree.
//  OUT:  CLI: mary-media-probe [--drive|--play|--shuffle|--find|--folders]
//  PIN:  --drive puts playback back.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryRuntime

var failures = 0
func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}
func heading(_ text: String) {
    print("\n\(text)"); print(String(repeating: "─", count: max(text.count, 30)))
}

let wantsDrive = CommandLine.arguments.dropFirst().contains("--drive")
let wantsShuffle = CommandLine.arguments.dropFirst().contains("--shuffle")
// `--shuffle-on`/`--shuffle-off` set and leave. `--shuffle` puts the found state back.
let setsShuffle: Bool? = CommandLine.arguments.contains("--shuffle-on") ? true
    : CommandLine.arguments.contains("--shuffle-off") ? false : nil

guard AXIsProcessTrusted() else {
    print("Accessibility is not granted — the probe needs it to read a transport.")
    exit(1)
}

// MARK: - The shipped configuration

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

// Media Skills with runtime readiness. Graph validity ≠ availability (blocked target class).
for runtime in load.snapshot.skills
    where runtime.skill.id.rawValue.hasPrefix("multimedia.") {
    let name = runtime.skill.modelExposure.invocationName ?? runtime.skill.id.rawValue
    check(runtime.availability.readiness == .ready,
          "\(name) is ready", "\(runtime.availability.readiness)")
}

let registrations = MaryRuntime.mediaSurfaceRegistrations(from: load.snapshot)
MediaSurfaceSupport.shared.reconcile(registrations)
check(!registrations.isEmpty, "a package declares a transport",
      registrations.map { $0.applicationID }.joined(separator: ", "))

guard let (registration, pid) = MediaSurfaceSupport.shared.resolve(nil) else {
    print("\n  ✗  no declared player is running. Open one and try again.\n")
    exit(1)
}
check(true, "and it is running", "\(registration.displayName) (pid \(pid))")

// MARK: - The read

heading("the transport")

guard let reading = MediaSurfaceAX.read(pid: pid, registration: registration) else {
    print("  ✗  the declared transport was not found.")
    print("     `\(registration.schema.transportLabel)` matched no group in the tree.")
    exit(1)
}
check(true, "the declared container was found", registration.schema.transportLabel)
check(reading.isPlaying != nil, "playing state read",
      reading.isPlaying.map { $0 ? "playing" : "paused" } ?? "neither label matched")
// LCD title may be absent while playing; that is not a failure.
print("      · current item: \(reading.title ?? "not exposed in this view")")
check(reading.isShuffling != nil, "shuffle read",
      reading.isShuffling.map(String.init) ?? "no label matched")
check(reading.isRepeating != nil, "repeat read",
      reading.isRepeating.map(String.init) ?? "no label matched")
check(reading.position != nil, "position read",
      reading.position.map { String(format: "%.1f%%", $0 * 100) } ?? "no slider")

print("\n      \(MediaSurfaceAdapter.spoken(reading, registration: registration))")

// MARK: - Driving

if wantsDrive {
    heading("the transport, driven")

    let before = reading.isPlaying
    check(MediaTransport.post(.playPause), "a media key was posted")
    try? await Task.sleep(nanoseconds: 700_000_000)

    let after = MediaSurfaceAX.read(pid: pid, registration: registration)
    check(after?.isPlaying != nil, "the transport read back",
          after?.isPlaying.map { $0 ? "playing" : "paused" } ?? "unreadable")
    // THE STATE ACTUALLY MOVED, which is the only thing that distinguishes a
    // key the system accepted from a key that did something.
    check(before != nil && after?.isPlaying != nil && before != after?.isPlaying,
          "and the state changed",
          "\(before.map(String.init) ?? "?") → \(after?.isPlaying.map(String.init) ?? "?")")

    // PUT IT BACK.
    _ = MediaTransport.post(.playPause)
    try? await Task.sleep(nanoseconds: 700_000_000)
    let restored = MediaSurfaceAX.read(pid: pid, registration: registration)
    check(restored?.isPlaying == before, "and was restored",
          restored?.isPlaying.map { $0 ? "playing" : "paused" } ?? "unreadable")
}

// MARK: - Shuffle

if let setsShuffle {
    heading("shuffle, set to \(setsShuffle)")
    let ok = await MediaSurfaceLibrary.pressShuffle(
        pid: pid, registration: registration, desired: setsShuffle)
    try? await Task.sleep(nanoseconds: 700_000_000)
    let after = MediaSurfaceAX.read(pid: pid, registration: registration)?.isShuffling
    check(ok, "the control answered")
    check(after == setsShuffle, "and shuffle is now \(setsShuffle)",
          after.map(String.init) ?? "unreadable")
}

// Shuffle: already-in state must press nothing; prove both against the live player.
if wantsShuffle {
    heading("shuffle, driven")

    let before = reading.isShuffling
    check(before != nil, "shuffle read before touching it",
          before.map(String.init) ?? "unreadable")

    if let before {
        let noop = await MediaSurfaceLibrary.pressShuffle(
            pid: pid, registration: registration, desired: before)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let unmoved = MediaSurfaceAX.read(pid: pid, registration: registration)?.isShuffling
        check(noop, "asking for the state it is already in succeeds")
        check(unmoved == before, "and does not toggle it",
              "\(before) → \(unmoved.map(String.init) ?? "?")")

        let flipped = await MediaSurfaceLibrary.pressShuffle(
            pid: pid, registration: registration, desired: !before)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let after = MediaSurfaceAX.read(pid: pid, registration: registration)?.isShuffling
        check(flipped, "asking for the opposite presses the control")
        check(after == !before, "and the state moved",
              "\(before) → \(after.map(String.init) ?? "?")")

        // PUT IT BACK, the same courtesy `--drive` pays the transport.
        _ = await MediaSurfaceLibrary.pressShuffle(
            pid: pid, registration: registration, desired: before)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let restored = MediaSurfaceAX.read(pid: pid, registration: registration)?.isShuffling
        check(restored == before, "and was restored",
              restored.map(String.init) ?? "unreadable")
    }
}

// Blind the transport label so the unnamed-container fallback actually runs.
heading("the transport, found without its name")

let blinded = MediaSurfaceRegistration(
    applicationID: registration.applicationID,
    bundleIdentifiers: registration.bundleIdentifiers,
    displayName: registration.displayName,
    schema: PluginMediaSurfaceSchema(
        transportLabel: "no group is called this",
        playingLabel: registration.schema.playingLabel,
        pausedLabel: registration.schema.pausedLabel,
        nextLabel: registration.schema.nextLabel,
        shuffle: registration.schema.shuffle,
        repeatMode: registration.schema.repeatMode,
        positionLabel: registration.schema.positionLabel))

if let recovered = MediaSurfaceAX.read(pid: pid, registration: blinded) {
    check(true, "the content rule found it anyway")
    check(recovered.title == reading.title, "and read the same track",
          recovered.title ?? "nothing")
    check(recovered.isPlaying == reading.isPlaying, "and the same state")
} else {
    check(false, "the content rule did not find the transport")
}

// MARK: - The library

heading("the library")

let playlists = await MediaSurfaceLibrary.playlists(pid: pid, registration: registration)
check(!playlists.isEmpty, "playlists were read", "\(playlists.count)")
if !playlists.isEmpty {
    print("      \(playlists.prefix(6).joined(separator: " · "))\(playlists.count > 6 ? " …" : "")")
    // THE SECTION HEADER MUST NOT BE IN ITS OWN LIST, and neither must the
    // navigation row that sits under it — the two mistakes the section rule
    // exists to prevent.
    let section = registration.schema.playlistSectionLabel ?? ""
    check(!playlists.contains(section), "the section header is not offered as a playlist")
    for skip in registration.schema.playlistSectionSkips {
        check(!playlists.contains(skip), "navigation is not offered as a playlist", skip)
    }
}

// MARK: - Finding one, pressing nothing

// THE READ-ONLY HALF OF THE SAME LADDER `--play` uses. Worth its own flag
// because the interesting failure is a MATCH failure, and running `--play` to
// discover one costs the user their music.
if let index = CommandLine.arguments.firstIndex(of: "--find"),
   index + 1 < CommandLine.arguments.count {
    let wanted = CommandLine.arguments[index + 1]
    heading("finding \"\(wanted)\"")
    switch SpokenTitleMatcher.resolve(wanted, in: playlists) {
    case .match(let title): check(true, "resolved", title)
    case .guessed(let title):
        check(true, "guessed (commit context off by default here)", title)
    case .ambiguous(let titles):
        check(true, "more than one answered to it", titles.joined(separator: ", "))
    case .none(let closest):
        check(false, "no playlist answered to it",
              "closest: \(closest.joined(separator: ", "))")
    }
}

// MARK: - Playing one, for real

if let index = CommandLine.arguments.firstIndex(of: "--play"),
   index + 1 < CommandLine.arguments.count {
    let wanted = CommandLine.arguments[index + 1]
    heading("playing \"\(wanted)\"")

    let before = MediaSurfaceAX.read(pid: pid, registration: registration)?.title
    switch await MediaSurfaceLibrary.play(
        playlistNamed: wanted, pid: pid, registration: registration
    ) {
    case .played(let name):
        check(true, "the playlist was started", name)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = MediaSurfaceAX.read(pid: pid, registration: registration)
        check(after?.isPlaying == true, "and the player is playing",
              after?.isPlaying.map(String.init) ?? "unreadable")
        // Title must change when exposed; silence is not a failure.
        if let now = after?.title {
            check(now != before, "and it is playing something new",
                  "\(before ?? "nothing") → \(now)")
        } else {
            print("      · track name not exposed in this view — cannot compare")
        }
    case .playedAsGuess(let name):
        check(true, "played as a guess (commit context off by default here)", name)
    case .ambiguous(let titles):
        check(false, "ambiguous", titles.joined(separator: ", "))
    case .noSuchPlaylist(let closest):
        check(false, "no such playlist", "closest: \(closest.joined(separator: ", "))")
    case .noLibrary:
        check(false, "no library was visible")
    case .couldNotPress:
        check(false, "found it but could not start it")
    }
}

// MARK: - Play mechanics diagnostic — did the row press actually navigate?

// `play()` reported success ("Hal → Hal") without the track changing. Measure
// each step raw: does pressing the row actually select it, how many "Play"
// buttons exist outside the transport (pagePlayLabel is the generic "Play",
// picked by largest area — ambiguous if more than one candidate exists), and
// does the content area actually show anything naming the target playlist.
if let index = CommandLine.arguments.firstIndex(of: "--diagnose"),
   index + 1 < CommandLine.arguments.count {
    let wanted = CommandLine.arguments[index + 1]
    heading("diagnosing \"\(wanted)\"")

    func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func label(_ element: AXUIElement) -> String? {
        AX.string(element, kAXTitleAttribute) ?? AX.string(element, kAXDescriptionAttribute)
    }

    let app = AXUIElementCreateApplication(pid)
    let windows = AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    print("      windows: \(windows.count)")
    for (i, window) in windows.enumerated() {
        let title = label(window) ?? "(untitled)"
        let frame = AX.frame(of: window)
        let minimized = AX.attribute(window, kAXMinimizedAttribute) as? Bool
        print("      [\(i)] \"\(title)\" frame=\(frame.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "?") minimized=\(minimized.map(String.init) ?? "?")")
    }

    guard let libraryLabel = registration.schema.libraryLabel else {
        print("  ✗  no libraryLabel declared."); exit(1)
    }
    var outline: AXUIElement?
    var outlineWindow = -1
    func findOutline(_ element: AXUIElement, windowIndex: Int, depth: Int) {
        guard outline == nil, depth < 40 else { return }
        if let l = label(element), folded(l) == folded(libraryLabel) {
            outline = element; outlineWindow = windowIndex; return
        }
        for child in AX.children(element) { findOutline(child, windowIndex: windowIndex, depth: depth + 1) }
    }
    for (i, window) in windows.enumerated() { findOutline(window, windowIndex: i, depth: 0) }
    guard let outline else { print("  ✗  outline not found"); exit(1) }
    check(true, "outline found", "in window[\(outlineWindow)]")

    // Expand every collapsed row, same rule `sidebarRows` uses in production.
    func expandAll(_ element: AXUIElement, depth: Int) {
        guard depth < 12 else { return }
        if AX.string(element, kAXRoleAttribute) == "AXRow",
           AX.attribute(element, kAXDisclosingAttribute) as? Bool == false {
            _ = AXUIElementSetAttributeValue(
                element, kAXDisclosingAttribute as CFString, true as CFTypeRef)
        }
        for child in AX.children(element) { expandAll(child, depth: depth + 1) }
    }
    expandAll(outline, depth: 0)
    try? await Task.sleep(nanoseconds: 700_000_000)

    var targetRow: AXUIElement?
    func findRow(_ element: AXUIElement, depth: Int) {
        guard targetRow == nil, depth < 12 else { return }
        if AX.string(element, kAXRoleAttribute) == "AXRow" {
            var name: String?
            func firstText(_ inner: AXUIElement, depth: Int) {
                guard name == nil, depth < 12 else { return }
                if let role = AX.string(inner, kAXRoleAttribute), role.contains("StaticText"),
                   let value = AX.string(inner, kAXValueAttribute), !value.isEmpty {
                    name = value; return
                }
                for child in AX.children(inner) { firstText(child, depth: depth + 1) }
            }
            firstText(element, depth: 0)
            if let name, folded(name) == folded(wanted) {
                targetRow = element
                print("      matched row: \"\(name)\"")
                return
            }
        }
        for child in AX.children(element) { findRow(child, depth: depth + 1) }
    }
    findRow(outline, depth: 0)
    guard let targetRow else {
        print("  ✗  row \"\(wanted)\" not found after expanding every folder."); exit(1)
    }

    let selectedBefore = AX.attribute(targetRow, kAXSelectedAttribute) as? Bool
    print("      row AXSelected before press: \(selectedBefore.map(String.init) ?? "unreadable")")
    let outlineFrame = AX.frame(of: outline)
    let windowFrame = AX.frame(of: windows[outlineWindow])
    let rowFrameBefore = AX.frame(of: targetRow)
    print("      window frame: \(windowFrame.map { "\($0)" } ?? "?")")
    print("      outline frame: \(outlineFrame.map { "\($0)" } ?? "?")")
    print("      row frame before scroll: \(rowFrameBefore.map { "\($0)" } ?? "?")")
    if let rf = rowFrameBefore, let wf = windowFrame {
        print("      row frame is within the WINDOW's visible bounds: \(wf.intersects(rf))")
    }

    let scrolled = AXUIElementPerformAction(
        targetRow, "AXScrollToVisible" as CFString) == .success
    print("      AXScrollToVisible on the row returned success: \(scrolled)")
    if scrolled {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let rowFrameAfter = AX.frame(of: targetRow)
        print("      row frame after scroll: \(rowFrameAfter.map { "\($0)" } ?? "?")")
    }

    // Off-screen (scrolled out of the viewport) — a coordinate click can't
    // land on it. Try setting selection as a pure state write instead of a
    // physical interaction.
    var settable: DarwinBoolean = false
    let selectableCheck = AXUIElementIsAttributeSettable(
        targetRow, kAXSelectedAttribute as CFString, &settable)
    print("      kAXSelectedAttribute settable: \(selectableCheck == .success && settable.boolValue)")
    let setSelected = AXUIElementSetAttributeValue(
        targetRow, kAXSelectedAttribute as CFString, true as CFTypeRef)
    check(setSelected == .success, "AXUIElementSetAttributeValue(AXSelected, true) returned success")
    try? await Task.sleep(nanoseconds: 500_000_000)
    let selectedAfterSet = AX.attribute(targetRow, kAXSelectedAttribute) as? Bool
    check(selectedAfterSet == true, "row AXSelected after the direct set",
          selectedAfterSet.map(String.init) ?? "unreadable")

    let pressed = AXUIElementPerformAction(targetRow, kAXPressAction as CFString) == .success
    check(pressed, "AXPress on the row returned success")
    if !pressed, selectedAfterSet != true, let frame = AX.frame(of: targetRow),
       frame.width > 1, frame.height > 1,
       let source = CGEventSource(stateID: .hidSystemState),
       let down = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseDown,
        mouseCursorPosition: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
        mouseButton: .left),
       let up = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseUp,
        mouseCursorPosition: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
        mouseButton: .left) {
        down.postToPid(pid); up.postToPid(pid)
        print("      AXPress failed and selection wasn't set — fell back to a synthetic click")
    }
    try? await Task.sleep(nanoseconds: 900_000_000)

    let selectedAfter = AX.attribute(targetRow, kAXSelectedAttribute) as? Bool
    check(selectedAfter == true, "row AXSelected after press",
          selectedAfter.map(String.init) ?? "unreadable")

    // Every "Play"-labeled button outside the transport — pagePlayLabel's
    // exact search, but listing every candidate instead of picking silently.
    var playButtons: [(window: Int, frame: CGRect)] = []
    func walkForPlay(_ element: AXUIElement, windowIndex: Int, depth: Int, insideTransport: Bool) {
        guard depth < 40 else { return }
        let elementLabel = label(element)
        let hereTransport = insideTransport
            || (elementLabel.map { folded($0) == folded(registration.schema.transportLabel) } ?? false)
        if !hereTransport,
           let role = AX.string(element, kAXRoleAttribute), role.contains("Button"),
           let l = elementLabel, folded(l) == folded("Play"),
           let frame = AX.frame(of: element) {
            playButtons.append((windowIndex, frame))
        }
        for child in AX.children(element) {
            walkForPlay(child, windowIndex: windowIndex, depth: depth + 1, insideTransport: hereTransport)
        }
    }
    for (i, window) in windows.enumerated() {
        walkForPlay(window, windowIndex: i, depth: 0, insideTransport: false)
    }
    print("      \"Play\" buttons outside the transport: \(playButtons.count)")
    for (i, b) in playButtons.enumerated() {
        let area = Int(b.frame.width * b.frame.height)
        print("        [\(i)] window=\(b.window) frame=\(Int(b.frame.width))x\(Int(b.frame.height))@\(Int(b.frame.minX)),\(Int(b.frame.minY)) area=\(area)")
    }
    let biggest = playButtons.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

    // Any visible text naming the target, outside the sidebar — did the
    // content area actually navigate to it.
    var hits: [(window: Int, text: String)] = []
    func walkForText(_ element: AXUIElement, windowIndex: Int, depth: Int, insideOutline: Bool) {
        guard depth < 40, hits.count < 8 else { return }
        let hereOutline = insideOutline || CFEqual(element, outline)
        if !hereOutline,
           let role = AX.string(element, kAXRoleAttribute), role.contains("StaticText"),
           let value = AX.string(element, kAXValueAttribute),
           folded(value).contains(folded(wanted)) {
            hits.append((windowIndex, value))
        }
        for child in AX.children(element) {
            walkForText(child, windowIndex: windowIndex, depth: depth + 1, insideOutline: hereOutline)
        }
    }
    for (i, window) in windows.enumerated() {
        walkForText(window, windowIndex: i, depth: 0, insideOutline: false)
    }
    print("      text naming \"\(wanted)\" outside the sidebar: \(hits.count)")
    for hit in hits { print("        window=\(hit.window): \"\(hit.text)\"") }

    if let biggest {
        let beforeTitle = MediaSurfaceAX.read(pid: pid, registration: registration)?.title
        // Frame alone isn't a handle — re-find the element at that frame to press it.
        var target: AXUIElement?
        func rewalk(_ element: AXUIElement, depth: Int) {
            guard target == nil, depth < 40 else { return }
            if let f = AX.frame(of: element), f == biggest.frame,
               let role = AX.string(element, kAXRoleAttribute), role.contains("Button") {
                target = element; return
            }
            for child in AX.children(element) { rewalk(child, depth: depth + 1) }
        }
        rewalk(windows[biggest.window], depth: 0)
        if let target {
            check(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success,
                  "pressed the largest Play button")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = MediaSurfaceAX.read(pid: pid, registration: registration)
        print("      transport after: title=\(after?.title ?? "unexposed") isPlaying=\(after?.isPlaying.map(String.init) ?? "?")")
        check(after?.title != beforeTitle, "and the title changed",
              "\(beforeTitle ?? "nothing") → \(after?.title ?? "nothing")")
    } else {
        print("  ✗  no \"Play\" button found outside the transport to press.")
    }
}

// MARK: - Sidebar disclosure diagnostic — measure before writing

// Raw AX, not `AXSnapshotBuilder` (its element table is internal to
// MaryPlugin, unreachable from this probe) — deliberately self-contained so
// this stays a pure measurement pass, nothing it discovers here is assumed
// by production code yet.
if CommandLine.arguments.dropFirst().contains("--folders") {
    heading("sidebar disclosure state")

    func rawValue(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
        else { return nil }
        return value
    }
    func rawString(_ element: AXUIElement, _ attr: String) -> String? {
        rawValue(element, attr) as? String
    }
    func rawBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        rawValue(element, attr) as? Bool
    }
    func rawSettable(_ element: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attr as CFString, &settable) == .success
            && settable.boolValue
    }
    func rawChildren(_ element: AXUIElement) -> [AXUIElement] {
        (rawValue(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
    func rawWindows(_ app: AXUIElement) -> [AXUIElement] {
        (rawValue(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }
    func rawLabel(_ element: AXUIElement) -> String? {
        rawString(element, kAXTitleAttribute as String)
            ?? rawString(element, kAXDescriptionAttribute as String)
    }
    func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    if let wantedLabel = registration.schema.libraryLabel {
        let app = AXUIElementCreateApplication(pid)
        var outline: AXUIElement?
        func find(_ element: AXUIElement, depth: Int) {
            guard outline == nil, depth < 40 else { return }
            if let label = rawLabel(element), folded(label) == folded(wantedLabel) {
                outline = element
                return
            }
            for child in rawChildren(element) { find(child, depth: depth + 1) }
        }
        for window in rawWindows(app) { find(window, depth: 0) }

        guard let outline else {
            print("  ✗  no element titled/described \"\(wantedLabel)\" was found.")
            exit(1)
        }
        check(true, "found the outline", wantedLabel)

        var rowCount = 0
        var collapsedCount = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 12 else { return }
            let role = rawString(element, kAXRoleAttribute as String) ?? "?"
            let children = rawChildren(element)
            if role == "AXRow" {
                rowCount += 1
                let label = rawLabel(element) ?? "(no label)"
                let disclosing = rawBool(element, kAXDisclosingAttribute as String)
                let settable = rawSettable(element, kAXDisclosingAttribute as String)
                let disclosedRows = rawValue(element, kAXDisclosedRowsAttribute as String)
                    as? [AXUIElement]
                let indent = String(repeating: "  ", count: depth)
                var line = "\(indent)· \(label) — children=\(children.count)"
                if let disclosing {
                    line += " disclosing=\(disclosing) settable=\(settable)"
                    if !disclosing { collapsedCount += 1 }
                }
                if let disclosedRows {
                    line += " disclosedRows=\(disclosedRows.count)"
                }
                print(line)
            }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(outline, depth: 0)

        print("\n      rows seen: \(rowCount), collapsed (disclosing=false): \(collapsedCount)")
        if collapsedCount > 0 {
            print("""
                  · at least one row is collapsed — its children, if any, are not
                    in this tree at all. Expanding (kAXDisclosingAttribute=true, or
                    pressing the disclosure control if the attribute is not
                    settable) before collecting rows is the fix `sidebarRows` needs.
                """)
        } else {
            print("      · no collapsed rows found — collapse a playlist folder and re-run to measure this case.")
        }
    } else {
        print("  ✗  this package declares no libraryLabel — nothing to search for.")
    }
}

heading("── THE VERDICT ──")
if failures == 0 {
    print("""
      A package's declared transport describes a live player: the container
      resolved, every state came back, and nothing named the application in
      Swift to do it.
    """)
} else {
    print("  \(failures) check(s) failed.")
}
exit(failures == 0 ? 0 : 1)
