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
        .executable(name: "mary-ax-probe", targets: ["AXProbe"]),
        .executable(name: "mary-voice-probe", targets: ["VoiceProbe"]),
        .executable(name: "mary-package-probe", targets: ["PackageProbe"]),
        .executable(name: "mary-totem-probe", targets: ["TotemProbe"]),
        .executable(name: "mary-behavior-probe", targets: ["BehaviorProbe"]),
        .executable(name: "mary-gpu-probe", targets: ["GPUProbe"]),
        .executable(name: "mary-media-probe", targets: ["MediaProbe"]),
    ],
    dependencies: [
        // FRIGATE IS MARY'S ONLY EXTERNAL INFERENCE DEPENDENCY, and MaryBrain
        // is its only consumer — enforced by `onlyBrainNamesFrigate`. It
        // vendors swift-transformers targets (Hub, Tokenizers, Jinja,
        // Generation, Models) under their original names, which is why a
        // second consumer of those names would need an alias map. Mary has
        // none: dropping WhisperKit removed the only other claimant, so the
        // alias wall that guarded this graph does not exist here.
        .package(path: "../Frigate"),
        // CONDUIT COMES FROM THE LOCAL CHECKOUT, not a git pin, and this is a
        // correctness requirement rather than a convenience: Seer and the
        // Totem node build against that same checkout, so a pin here could
        // drift from the wire contract the servers actually speak — and a
        // drifted contract fails at runtime, on a machine, in a way no build
        // notices.
        .package(url: "https://github.com/riteshpakala/Granite.git", branch: "main"),
        .package(path: "../Conduit"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
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
        // Fixtures shared by more than one test target. A non-test target
        // because a testTarget cannot expose its declarations to another one.
        .target(
            name: "MaryFoundationTestSupport",
            dependencies: ["MaryFoundation"],
            path: "Sources/TestSupport/MaryFoundationTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - MaryAmbient — THE AMBIENT LAYER: the tiered context store
        // (tier 0 the accessibility surface, tier 1 per-application facts,
        // tier 2 selection and attention), realms, passages, containers, and
        // the behavioural capture built from what a turn actually injected.
        // Knows nothing about inference, adapters, or any specific
        // application — depends on MaryFoundation and the system frameworks
        // alone, deliberately, so the paradigm can be read, reasoned about
        // and ported without dragging a model runtime behind it. The layering
        // test enforces that edge; it is the whole portability claim.
        .target(
            name: "MaryAmbient",
            dependencies: ["MaryFoundation"],
            path: "Sources/MaryAmbient",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryAmbientTests",
            dependencies: ["MaryAmbient", "MaryFoundation"],
            path: "Tests/MaryAmbientTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - MaryAdapters — THE ADAPTER LAYER: the contract a compiled
        // provider satisfies, the accessibility engine that reads the screen,
        // and the generic adapters themselves. The word "plugin" names
        // nothing here — a Plugin is a declarative package, and everything in
        // this target is generic by construction: no file names an
        // application, and what an adapter serves at any moment comes from a
        // registration rather than from its own source.
        .target(
            name: "MaryAdapters",
            dependencies: ["MaryFoundation", "MaryAmbient"],
            path: "Sources/MaryAdapters",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Validates and seals the shipped .mary packages. A package that
        // fails to decode is a package that quietly is not installed, which
        // is exactly the failure a tool should catch and a comment cannot.
        .executableTarget(
            name: "PackageProbe",
            dependencies: ["MaryFoundation"],
            path: "Sources/Probes/PackageProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The one live check the suite cannot make: what the engine sees when
        // it looks at a real application, driven through the real path.
        .executableTarget(
            name: "AXProbe",
            dependencies: ["MaryAdapters", "MaryAmbient", "MaryFoundation"],
            path: "Sources/Probes/AXProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryAdaptersTests",
            dependencies: ["MaryAdapters", "MaryAmbient", "MaryFoundation"],
            path: "Tests/MaryAdaptersTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - MaryVoice — EARS AND MOUTH, and nothing about meaning. The
        // mic, the VAD that decides where an utterance ends, transcription,
        // the wake word, the speaker floor, and two synthesis backends
        // (Kokoro on-device, Seer in the cloud).
        //
        // DEPENDS ON MaryFoundation ALONE — not on MaryAmbient, and the
        // layering test holds it there. A voice layer that could read the
        // ambient store would start deciding WHAT to say, and the whole point
        // of the split is that it only decides WHEN to listen and how a
        // sentence should sound. The one domain type it touches is
        // `BehavioralActionRecord`, which it relays and never composes.
        .target(
            name: "MaryVoice",
            dependencies: ["MaryFoundation"],
            path: "Sources/MaryVoice",
            resources: [
                .copy("Resources/KokoroModels")
            ],
            // The Kokoro port is a faithful translation of pre-strict-
            // concurrency CoreML/AVFoundation code.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Speaks, listens, and prints what the VAD decided — the only way to
        // check a thing whose whole output is sound.
        .executableTarget(
            name: "VoiceProbe",
            dependencies: ["MaryVoice"],
            path: "Sources/Probes/VoiceProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryVoiceTests",
            dependencies: ["MaryVoice"],
            path: "Tests/MaryVoiceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - MaryBrain — WHAT TO SAY AND WHAT TO DO. The inference
        // engines (one local MLX, one hosted through Seer), the prompt
        // catalog, the turn loop, and the ability pipeline that turns a
        // model's tool call into an act on the Mac.
        //
        // THE ONLY FRIGATE CONSUMER. Everything below it — ambient, adapters,
        // voice — is testable without a model runtime, and this is the target
        // where that stops being true.
        .target(
            name: "MaryBrain",
            dependencies: [
                "MaryFoundation",
                "MaryAmbient",
                "MaryAdapters",
                "MaryVoice",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLXLLM", package: "Frigate"),
            ],
            path: "Sources/MaryBrain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - MaryTotem — Mary's direct line to the local Totem node
        // (gRPC :9090). Wraps the Conduit contract package behind a small
        // facade so no other target imports generated protos.
        //
        // STANDING RULE: only MaryRuntime and the Mary app consume MaryTotem.
        // MaryBrain and MaryVoice must never depend on it — a brain that
        // could reach the transport would start deciding what to persist,
        // which is the runtime's decision to make.
        .target(
            name: "MaryTotem",
            dependencies: [
                .product(name: "Conduit", package: "Conduit"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ],
            path: "Sources/MaryTotem",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TotemProbe",
            dependencies: ["MaryTotem"],
            path: "Sources/Probes/TotemProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryTotemTests",
            dependencies: [
                "MaryTotem",
                .product(name: "Conduit", package: "Conduit"),
            ],
            path: "Tests/MaryTotemTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - MaryRuntime — the composition root and the non-UI services.
        // The long-lived actors, the Granite services that own durable state,
        // and their models. NO SwiftUI here: SwiftUI lives only in the app
        // target, and the split is what keeps the runtime testable headless.
        .target(
            name: "MaryRuntime",
            dependencies: [
                "MaryFoundation",
                "MaryAmbient",
                "MaryAdapters",
                "MaryVoice",
                "MaryBrain",
                "MaryTotem",
                .product(name: "Granite", package: "Granite"),
            ],
            path: "Sources/MaryRuntime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - Mary — the SwiftUI app: components, view models, the design
        // primitives, the headless probe entry points, and main.swift. Talks
        // to MaryRuntime's actors and Granite services through
        // `package`-level declarations — visible across targets in this one
        // package without becoming public API.
        .executableTarget(
            name: "Mary",
            dependencies: [
                "MaryRuntime",
                "MaryFoundation",
                "MaryAmbient",
                "MaryAdapters",
                "MaryVoice",
                "MaryBrain",
                "MaryTotem",
                .product(name: "Granite", package: "Granite"),
                .product(name: "GraniteUI", package: "Granite"),
            ],
            path: "Sources/MaryApp",
            // MLX types are not Sendable; the same precedent the brain uses.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MaryTests",
            dependencies: ["Mary", "MaryRuntime"],
            path: "Tests/MaryTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The one live check the suite cannot make about the codec: whether
        // its halves MEET — a real accessibility read reaching a value
        // composed three layers away, with its geometry intact.
        .executableTarget(
            name: "BehaviorProbe",
            dependencies: ["MaryRuntime", "MaryBrain", "MaryAdapters", "MaryAmbient", "MaryFoundation"],
            path: "Sources/Probes/BehaviorProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Whether the on-device engine has a GPU to run on — asked BEFORE a
        // 4 GB download rather than after it. `swift build` cannot compile
        // Metal, so this is the one build product that can go missing without
        // anything failing until first use.
        .executableTarget(
            name: "GPUProbe",
            dependencies: ["MaryBrain"],
            path: "Sources/Probes/GPUProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The join no test can make: a package's declared transport labels on
        // one side, a live player's Accessibility tree on the other.
        .executableTarget(
            name: "MediaProbe",
            dependencies: ["MaryRuntime", "MaryBrain", "MaryAdapters", "MaryFoundation"],
            path: "Sources/Probes/MediaProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryRuntimeTests",
            dependencies: ["MaryRuntime"],
            path: "Tests/MaryRuntimeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "MaryBrainTests",
            dependencies: [
                "MaryBrain",
                "MaryAdapters",
                "MaryFoundationTestSupport",
            ],
            path: "Tests/MaryBrainTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "MaryFoundationTests",
            dependencies: ["MaryFoundation", "MaryFoundationTestSupport"],
            path: "Tests/MaryFoundationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
