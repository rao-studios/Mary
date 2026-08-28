//
//  MaryGPU.swift
//  MaryBrain
//
//  WHETHER MLX CAN REACH THE GPU — which on this build means one question:
//  is `mlx.metallib` where MLX looks for it?
//
//  THE FAILURE THIS EXISTS TO NAME. `swift build` cannot compile Metal.
//  Xcode's package support can, and turns the vendored `.metal` sources into
//  a `default.metallib` inside `Frigate_Cmlx.bundle`; the SwiftPM command line
//  has no Metal step at all, so every binary under `.build` ships without the
//  shaders unless something puts them there. `scripts/build-metallib.sh` is
//  that something. When it has not run, the first GPU operation dies with:
//
//    MLX error: Failed to load the default metallib. library not found
//    library not found library not found library not found
//
//  — and that is the whole diagnostic. It does not say where it looked.
//
//  WHY THIS IS A FILE CHECK AND NOT SIMPLY "TRY IT". MLX reports the failure
//  by throwing `std::runtime_error` from C++. That does not become a Swift
//  error a caller can catch; it terminates the process. So a self-check whose
//  method is "perform an operation and see" CRASHES on precisely the broken
//  setup it was written to diagnose. Reading the search path answers the same
//  question, safely, and answers the more useful half of it too — WHICH rung
//  responded, or that none did.
//
//  THE LADDER BELOW MIRRORS `load_default_library` in
//  `mlx/backend/metal/device.cpp`. If that function changes, this becomes a
//  confident lie, so it is written to be read next to the original.
//

import Foundation
import MLX

/// Where MLX's Metal library is, or is not.
public enum MaryGPU {

    /// One rung of MLX's search, and whether anything is on it.
    public struct Candidate: Sendable, Equatable {
        /// The rung's own description, in MLX's terms.
        public let rung: String
        public let path: String
        public let exists: Bool
    }

    public struct Report: Sendable, Equatable {
        /// True when at least one rung holds a file. MLX takes the first.
        public var isSatisfied: Bool { found != nil }
        /// The rung MLX will actually load from.
        public let found: Candidate?
        /// Every rung, in MLX's own order — the useful part when none hit.
        public let searched: [Candidate]
    }

    /// The directory MLX resolves its colocated rungs against: the one holding
    /// the running executable.
    ///
    /// `executablePath` AND NOT the bundle, because MLX asks the same question
    /// of the loaded binary — a CLI probe in `.build/debug` and an app binary
    /// in `Mary.app/Contents/MacOS` both answer for themselves, which is why
    /// the same file has to be copied to both.
    public static var binaryDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    /// Read the search path. Touches no MLX symbol and cannot fail.
    public static func report(binaryDirectory: URL = MaryGPU.binaryDirectory) -> Report {
        // ORDERED AS MLX ORDERS THEM. The third rung of the original —
        // `default.metallib` inside a loaded SwiftPM bundle — is deliberately
        // absent: it is reachable only through `NS::Bundle::allBundles`, which
        // no file test can stand in for. It is also not a road out of this
        // build. Frigate defines `SWIFTPM_BUNDLE` as "mlx-swift_Cmlx", a name
        // inherited from upstream that nothing here produces, since SwiftPM
        // names a bundle after ITS OWN package — `Frigate_Cmlx`.
        let rungs: [(String, URL)] = [
            ("colocated mlx.metallib", binaryDirectory
                .appendingPathComponent("mlx.metallib")),
            ("colocated Resources/mlx.metallib", binaryDirectory
                .appendingPathComponent("Resources/mlx.metallib")),
            ("colocated Resources/default.metallib", binaryDirectory
                .appendingPathComponent("Resources/default.metallib")),
            // METAL_PATH, the compile-time constant: a RELATIVE path, so it
            // resolves against the working directory rather than the binary
            // — which is why it almost never answers, and why it is last.
            ("METAL_PATH (relative to cwd)", URL(
                fileURLWithPath: "default.metallib",
                relativeTo: URL(fileURLWithPath: FileManager.default
                    .currentDirectoryPath))),
        ]
        let searched = rungs.map { rung, url in
            Candidate(
                rung: rung,
                path: url.standardizedFileURL.path,
                exists: FileManager.default.fileExists(
                    atPath: url.standardizedFileURL.path))
        }
        return Report(found: searched.first(where: \.exists), searched: searched)
    }

    public enum Exercise: Sendable {
        case success(String)
        case failure(String)
    }

    /// Actually compute something on the GPU, proving the library loads rather
    /// than merely exists.
    ///
    /// CALL THIS ONLY WHEN `report().isSatisfied`. The failure it would
    /// otherwise hit is a C++ `std::runtime_error` crossing into Swift, which
    /// terminates the process instead of returning — there is no `catch` that
    /// helps, which is why the guard is the caller's job and is stated here
    /// rather than attempted below.
    ///
    /// A MATMUL AND NOT AN ADDITION: elementwise work can be served without
    /// ever reaching for a compiled kernel, and the point is to make MLX load
    /// one. The result is checked because a kernel that runs and returns
    /// nonsense is its own kind of broken.
    public static func exercise() async -> Exercise {
        guard report().isSatisfied else {
            return .failure(remedy())
        }
        let started = Date()
        let side = 64
        let a = MLXArray.ones([side, side])
        let product = a.matmul(a)
        product.eval()
        let corner = product[0, 0].item(Float.self)
        let milliseconds = Date().timeIntervalSince(started) * 1000
        guard corner == Float(side) else {
            return .failure(
                "the GPU ran but answered \(corner) where \(side) was expected")
        }
        return .success(String(
            format: "%d×%d matmul on %@, correct, in %.0f ms",
            side, side, Device.defaultDevice().description, milliseconds))
    }

    /// What to tell a person when the GPU cannot start — the sentence the raw
    /// MLX message does not manage.
    public static func remedy() -> String {
        """
        No MLX Metal library found. Run ./scripts/build-metallib.sh, which \
        compiles Frigate's vendored shaders into .build/<config>/mlx.metallib \
        — `swift build` cannot do it, because SwiftPM has no Metal step.
        """
    }
}
