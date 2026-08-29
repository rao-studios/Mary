//
//  main.swift
//  MediaProbe — `mary-media-probe`
//
//  DOES THE DECLARED TRANSPORT ACTUALLY READ? The join no test can make: a
//  package's `mediaSurface` block on one side, a running player's live
//  Accessibility tree on the other, and a claim that the labels in the first
//  describe the second.
//
//    mary-media-probe                     # read the transport and the library
//    mary-media-probe --drive             # press pause, then press it back
//    mary-media-probe --play <playlist>   # actually start one, for real
//    mary-media-probe --shuffle           # set shuffle, read it back, put it back
//    mary-media-probe --shuffle-on|-off   # set it and LEAVE it there
//    mary-media-probe --find <name>       # resolve a spoken name, press nothing
//
//  `--drive` TOUCHES REAL PLAYBACK, so it puts back what it changed: one
//  toggle, a read, the opposite toggle. A probe that left the music paused
//  would be a probe nobody runs twice.
//

import AppKit
import Foundation
import MaryPlugin
import MaryBrain
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
// SET AND LEAVE, unlike every other driving flag here. `--shuffle` puts back
// what it found, which is right for a probe and useless for the one job of
// returning a player to a state something else disturbed.
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

// EVERY MEDIA SKILL, WITH THE READINESS THE RUNTIME ACTUALLY GAVE IT. Graph
// validity is not availability: `mary-package-probe check` was green for the
// whole stretch during which `control_playback`, `now_playing`,
// `list_playlists` and `play_playlist` were installed and BLOCKED for want of
// a declared target class (see MediaSurfaceAdapter's own header). That failure
// is invisible everywhere except here, so it is asserted here.
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
// NOT A FAILURE WHEN ABSENT. The player exposes its LCD in some window
// states and not others while still reporting itself as playing, so a probe
// that failed here would be red about the application's behaviour rather
// than Mary's.
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

// THE ONE CONTROL WHOSE LABEL IS ITS STATE, which is why setting it needs a
// read first and why that is worth proving against a live player rather than
// a fixture. `pressShuffle` is asked for a state it is ALREADY IN as well as
// one it is not: the first must press nothing and still report success, and
// getting that backwards is invisible in a unit test and audible here.
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

// THE FALLBACK, EXERCISED ON PURPOSE. The named container is found in the
// main window, so the content rule would otherwise never run here — and the
// view it exists for (full-screen Now Playing, whose transport group carries
// no label at all) is not one a probe can reliably put the player into. So
// the probe breaks the NAME instead: same live tree, same controls, a
// container label that matches nothing.
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
        // THE TRACK ACTUALLY CHANGED — what separates "a play button was
        // pressed" from "the playlist started". Pressing the transport by
        // mistake resumes the previous song and passes every other check.
        //
        // ASSERTED ONLY WHEN THE PLAYER IS EXPOSING TITLES. It does not
        // always (see `Reading.title`), and a probe that failed on the
        // application's silence would be red about the wrong thing.
        if let now = after?.title {
            check(now != before, "and it is playing something new",
                  "\(before ?? "nothing") → \(now)")
        } else {
            print("      · track name not exposed in this view — cannot compare")
        }
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
