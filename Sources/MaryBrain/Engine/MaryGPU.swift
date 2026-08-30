//
//  MaryGPU.swift
//  MaryBrain
//
//  WHAT: Whether MLX can reach the GPU (`mlx.metallib` where MLX looks).
//  IN:   engine warmup
//  OUT:  reachable / honest miss
//  PIN:  File check, not "try it" — MLX's error does not say where it looked.
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

    /// The directory MLX resolves its colocated rungs against: the one holding the running executable.
    public static var binaryDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    /// Read the search path. Touches no MLX symbol and cannot fail.
    public static func report(binaryDirectory: URL = MaryGPU.binaryDirectory) -> Report {
        // ORDERED AS MLX ORDERS THEM. The third rung of the original — `default.metallib` inside a loaded SwiftPM bundle
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

    /// Actually compute something on the GPU, proving the library loads rather than merely exists.
    /// A MATMUL AND NOT AN ADDITION: elementwise work can be served without ever reaching for a compiled kernel
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
