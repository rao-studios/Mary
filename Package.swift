// swift-tools-version: 6.0
// Mary — a macOS ambient-intelligence assistant: accessibility-first perception,
// declarative Plugins carried out by voice, Seer for every hosted call and an
// on-device MLX engine for the silent skill lane. Standalone SwiftPM executable.
//
// ONE PACKAGE, MANY TARGETS. The layering between targets is real and worth
// keeping; a per-boundary manifest is not. Each layer is a target under
// Sources/, every dependency edge is a target-name string, and the layering
// rules are enforced by reading this manifest AS TEXT
// (Tests/MaryFoundationTests/PackageLayeringTests.swift) — SwiftPM exposes no
// build-time hook for "this target may not depend on that product."
//
// THE WORD "PLUGIN" NAMES NO SWIFT CODE. A Plugin is a declarative package
// under Abilities/ (`*.mary`). Compiled providers that satisfy what a Plugin
// declares are ADAPTERS, and they live in MaryAdapters. There is no native
// plugin concept anywhere in this package.
//
// ACCESSIBILITY IS TIER 0. MaryAmbient's context store takes the AX surface as
// its foundation — what is actually on screen — with per-application facts and
// selection layered on top. MaryAmbient depends on MaryFoundation ALONE, so
// that paradigm can be read, reasoned about and ported without dragging a model
// runtime or a Mac integration behind it. The layering test is what keeps that
// claim honest.
//
// PLATFORM FLOOR. SwiftPM has no per-target platform, so the whole package sits
// at macOS 26 — needed for `SpeechAnalyzer`/`SpeechTranscriber`, MaryVoice's
// only API for long-form continuous on-device transcription. STRING FORM for
// the version, not `.v26`: that symbol needs swift-tools-version 6.2, and
// bumping the tools version changes manifest defaults across every target for
// one number.
//
// NO MODULE ALIASES, DELIBERATELY. Bonnie carried a five-target alias map so
// Frigate's vendored swift-transformers (`Hub`, `Tokenizers`, `Jinja`,
// `Generation`, `Models`) could coexist with the real swift-transformers that
// WhisperKit dragged in. Mary transcribes with Apple's SpeechAnalyzer and names
// WhisperKit nowhere, so the collision cannot arise and the alias wall — the
// most fragile thing in that manifest — does not exist here. Adding WhisperKit
// back would mean rebuilding it; the layering test asserts nothing names it.

import PackageDescription

let package = Package(
    name: "Mary",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        // Friendly CLI names for the probe executables go here as their
        // targets land (mary-voice-probe with MaryVoice, mary-totem-probe with
        // MaryTotem). SwiftPM's implicit per-executable-target product would
        // otherwise name them after the target; `Mary` itself needs no entry,
        // since its implicit product already carries the target's own name.
    ],
    dependencies: [
    ],
    targets: [
        // MARK: - MaryFoundation — the schema layer: Plugin package grammar,
        // codec and integrity digest, value envelopes, and the pure geometry
        // types (AXFrame, AXElementRecord) the ambient layer speaks in.
        // Pure data: zero I/O, zero CoreGraphics, depends on nothing. A schema
        // type placed here reaches every other layer with no manifest edit.
        .target(
            name: "MaryFoundation",
            path: "Sources/MaryFoundation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryFoundationTests",
            dependencies: ["MaryFoundation"],
            path: "Tests/MaryFoundationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
