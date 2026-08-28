//
//  main.swift
//  MediaProbe — `mary-media-probe`
//
//  DOES THE DECLARED TRANSPORT ACTUALLY READ? The join no test can make: a
//  package's `mediaSurface` block on one side, a running player's live
//  Accessibility tree on the other, and a claim that the labels in the first
//  describe the second.
//
//    mary-media-probe             # read the transport
//    mary-media-probe --drive     # and press pause, then press it back
//
//  `--drive` TOUCHES REAL PLAYBACK, so it puts back what it changed: one
//  toggle, a read, the opposite toggle. A probe that left the music paused
//  would be a probe nobody runs twice.
//

import AppKit
import Foundation
import MaryAdapters
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
check(reading.title != nil, "current item read", reading.title ?? "nothing")
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
