// swift-tools-version: 6.0
// WHAT: One SwiftPM package. Targets under Sources/, layered by name.
// OUT:  MaryFoundation → MaryAmbient → MaryPlugin
//            → MaryVoice / MaryBrain → MaryTotem → MaryRuntime → Mary
// PIN:  Layering is enforced by reading this file as text
//       (PackageLayeringTests). Plugin = Abilities/*.mary; adapters live in
//       MaryPlugin. AX is tier 0 (MaryAmbient → MaryFoundation only).
//       Platform is macOS "26.0" (string, not .v26) for SpeechAnalyzer.
//       No module aliases. Frigate only through MaryBrain.

import PackageDescription

let package = Package(
    name: "Mary",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        // Probe CLIs: explicit product names. `Mary` uses the implicit product.
        .executable(name: "mary-ax-probe", targets: ["AXProbe"]),
        .executable(name: "mary-voice-probe", targets: ["VoiceProbe"]),
        .executable(name: "mary-package-probe", targets: ["PackageProbe"]),
        .executable(name: "mary-totem-probe", targets: ["TotemProbe"]),
        .executable(name: "mary-behavior-probe", targets: ["BehaviorProbe"]),
        .executable(name: "mary-gpu-probe", targets: ["GPUProbe"]),
        .executable(name: "mary-corpus-probe", targets: ["CorpusProbe"]),
        .executable(name: "mary-media-probe", targets: ["MediaProbe"]),
    ],
    dependencies: [
        // Frigate: only MaryBrain (onlyBrainNamesFrigate). No alias map.
        .package(path: "../Frigate"),
        // Conduit: local checkout, same wire as the Seer/Totem node.
        .package(url: "https://github.com/riteshpakala/Granite.git", branch: "main"),
        .package(path: "../Conduit"),
        .package(path: "../Fleet"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
    ],
    targets: [
        // MARK: - MaryFoundation — schema (Plugin grammar, codecs, AXFrame). No I/O.
        .target(
            name: "MaryFoundation",
            path: "Sources/MaryFoundation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Shared fixtures. Library target: testTargets cannot export to each other.
        .target(
            name: "MaryFoundationTestSupport",
            dependencies: ["MaryFoundation"],
            path: "Sources/TestSupport/MaryFoundationTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - MaryAmbient — tiers 0/1/2 (surface / facts / selection).
        // PIN: depends on MaryFoundation only.
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

        // MARK: - MaryPlugin — adapters + AX engine. No file names an app.
        .target(
            name: "MaryPlugin",
            dependencies: ["MaryFoundation", "MaryAmbient"],
            path: "Sources/MaryPlugin",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("EventKit")
            ]
        ),
        // Seals shipped Abilities/*.mary (decode-or-fail).
        .executableTarget(
            name: "PackageProbe",
            dependencies: ["MaryFoundation"],
            path: "Sources/Probes/PackageProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live AX walk against a real app.
        .executableTarget(
            name: "AXProbe",
            dependencies: ["MaryPlugin", "MaryAmbient", "MaryFoundation"],
            path: "Sources/Probes/AXProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryPluginTests",
            dependencies: ["MaryPlugin", "MaryAmbient", "MaryFoundation"],
            path: "Tests/MaryPluginTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - MaryVoice — mic → VAD → STT → TTS. Relays BehavioralActionRecord.
        // PIN: MaryFoundation only — must not decide what to say.
        .target(
            name: "MaryVoice",
            dependencies: ["MaryFoundation"],
            path: "Sources/MaryVoice",
            resources: [
                .copy("Resources/KokoroModels")
            ],
            // Kokoro: pre-strict-concurrency CoreML/AVFoundation.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live speak/listen — output is sound.
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

        // MARK: - MaryBrain — turn loop, prompts, Skill pipeline. Only Frigate consumer.
        .target(
            name: "MaryBrain",
            dependencies: [
                "MaryFoundation",
                "MaryAmbient",
                "MaryPlugin",
                "MaryVoice",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "FleetCore", package: "Fleet"),
                .product(name: "FleetInference", package: "Fleet"),
            ],
            path: "Sources/MaryBrain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - MaryTotem — gRPC :9090 facade over Conduit.
        // PIN: only MaryRuntime and Mary consume this.
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

        // MARK: - MaryRuntime — composition root + Granite services. No SwiftUI.
        .target(
            name: "MaryRuntime",
            dependencies: [
                "MaryFoundation",
                "MaryAmbient",
                "MaryPlugin",
                "MaryVoice",
                "MaryBrain",
                "MaryTotem",
                .product(name: "Granite", package: "Granite"),
            ],
            path: "Sources/MaryRuntime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - Mary — SwiftUI app. Talks to MaryRuntime via `package`.
        .executableTarget(
            name: "Mary",
            dependencies: [
                "MaryRuntime",
                "MaryFoundation",
                "MaryAmbient",
                "MaryPlugin",
                "MaryVoice",
                "MaryBrain",
                "MaryTotem",
                .product(name: "Granite", package: "Granite"),
                .product(name: "GraniteUI", package: "Granite"),
            ],
            path: "Sources/MaryApp",
            // MLX types are not Sendable (same as MaryBrain).
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

        // Live AX read through the behavioral codec.
        .executableTarget(
            name: "BehaviorProbe",
            dependencies: ["MaryRuntime", "MaryBrain", "MaryPlugin", "MaryAmbient", "MaryFoundation"],
            path: "Sources/Probes/BehaviorProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live corpus: shipped declaration vs a real editor project.
        // GPUProbe (below): Metal GPU check before a 4 GB model download.
        .executableTarget(
            name: "CorpusProbe",
            dependencies: ["MaryRuntime", "MaryBrain", "MaryPlugin", "MaryAmbient", "MaryFoundation"],
            path: "Sources/Probes/CorpusProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GPUProbe",
            dependencies: ["MaryBrain"],
            path: "Sources/Probes/GPUProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live media: package transport labels vs a player's AX tree.
        .executableTarget(
            name: "MediaProbe",
            dependencies: ["MaryRuntime", "MaryBrain", "MaryPlugin", "MaryFoundation"],
            path: "Sources/Probes/MediaProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaryRuntimeTests",
            dependencies: [
                "MaryRuntime",
                "MaryBrain",
                "MaryPlugin",
                "MaryFoundation",
                "MaryFoundationTestSupport",
                "MaryAmbient",
                "MaryTotem",
            ],
            path: "Tests/MaryRuntimeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "MaryBrainTests",
            dependencies: [
                "MaryBrain",
                "MaryPlugin",
                "MaryFoundation",
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
