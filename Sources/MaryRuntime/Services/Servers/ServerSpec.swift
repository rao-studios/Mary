//
//  ServerSpec.swift
//  MaryRuntime
//
//  WHAT: Pure description of one local server Mary manages (no Process, no IO).
//  OUT:  LocalStackManager spawn / health-check
//  PIN:  Side-effect free so argument building is unit-testable.
//

import Foundation

package struct ServerSpec: Sendable, Equatable, Identifiable {

    package enum Kind: String, Sendable, CaseIterable, Identifiable {
        case sewn = "Sewn"
        case thread = "Thread"
        case fleet = "Fleet"
        package var id: String { rawValue }
    }

    package var kind: Kind
    /// Binary name inside the checkout's .build directory.
    package var executableName: String
    /// Absolute, tilde-expanded checkout root. Children run with this as cwd
    /// so each server's own `.env` loads (Sewn needs Supabase keys from it).
    package var checkoutPath: String
    package var arguments: [String]
    package var healthURL: URL

    package var id: String { kind.rawValue }

    // MARK: - Binary resolution

    package enum BinaryLocation: Equatable {
        case built(path: String, configuration: String)   // "release" | "debug"
        case notBuilt
    }

    /// Release beats debug; a missing binary is a UI state ("Build"), never a
    /// surprise multi-minute build at boot.
    package func resolveBinary(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> BinaryLocation {
        for configuration in ["release", "debug"] {
            let path = "\(checkoutPath)/.build/\(configuration)/\(executableName)"
            if fileExists(path) {
                return .built(path: path, configuration: configuration)
            }
        }
        return .notBuilt
    }

    // MARK: - The two servers

    /// Sewn: HTTP API on `port`, gRPC mothership (which Thread dials) on
    /// `grpcPort`. The mothership is always on — `--enable-threads` no longer
    /// exists as a flag; don't pass it.
    package static func sewn(checkoutPath: String, port: Int, grpcPort: Int) -> ServerSpec {
        ServerSpec(
            kind: .sewn,
            executableName: "sewn-server",
            checkoutPath: expand(checkoutPath),
            arguments: [
                "--host", "127.0.0.1",
                "--port", String(port),
                "--grpc-port", String(grpcPort),
            ],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    /// Thread: HTTP `port`, gRPC `grpcPort`, dials Sewn. nodeID pins table-<uuid>.
    /// graphBackend pinned — mlx without metallib degrades to keyword-only.
    package static func thread(
        checkoutPath: String,
        port: Int,
        grpcPort: Int,
        mothershipHost: String = "127.0.0.1",
        mothershipGRPCPort: Int,
        nodeID: String,
        graphBackend: String
    ) -> ServerSpec {
        var arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--grpc-port", String(grpcPort),
            "--mothership-host", mothershipHost,
            "--mothership-grpc-port", String(mothershipGRPCPort),
        ]
        if !nodeID.isEmpty {
            arguments += ["--node-id", nodeID]
        }
        if !graphBackend.isEmpty {
            arguments += ["--graph-backend", graphBackend]
        }
        return ServerSpec(
            kind: .thread,
            executableName: "thread",
            checkoutPath: expand(checkoutPath),
            arguments: arguments,
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    /// Fleet: HTTP `/health` on `port`, FleetLoRA gRPC on `grpcPort`. Pulls
    /// training corpora from Thread's direct gRPC.
    package static func fleet(
        checkoutPath: String,
        port: Int,
        grpcPort: Int,
        threadGRPCPort: Int
    ) -> ServerSpec {
        ServerSpec(
            kind: .fleet,
            executableName: "fleet",
            checkoutPath: expand(checkoutPath),
            arguments: [
                "serve",
                "--port", String(port),
                "--grpc-port", String(grpcPort),
                "--thread-host", "127.0.0.1",
                "--thread-grpc-port", String(threadGRPCPort),
            ],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Defaults (overridden by ConfigService in the app)

    package enum Defaults {
        package static let sewnCheckoutPath = "~/Documents/rao/repositories/Sewn"
        package static let threadCheckoutPath = "~/Documents/rao/repositories/Thread"
        package static let sewnPort = 8080
        package static let sewnGRPCPort = 9091
        package static let threadPort = 8081
        package static let threadGRPCPort = 9090
        package static let threadGraphBackend = "mistral"
        /// Vendor model behind Sewn's `/v1/embed`.
        package static let sewnEmbeddingModel = "mistral-embed"
        package static let fleetCheckoutPath = "~/Documents/rao/repositories/Fleet"
        package static let fleetPort = 8083
        package static let fleetGRPCPort = 9093
        package static let sewnEmail = "admin@seer.social"
        package static let sewnPassword = "cogqab-jazhEv-5rudhi"
    }
}

/// Node UUID is the DB identity. Config → persisted node-id → mint. Never mint over existing.
package enum ThreadNodeIdentity {
    static var persistedPath: String {
        ("~/Documents/thread-db/node-id" as NSString).expandingTildeInPath
    }

    /// Node identity is a UUID, canonicalized via UUID.uuidString. Anything else is nil.
    package static func canonical(_ value: String) -> String? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString
    }

    /// Existing identity or nil — scanner labels live/orphaned against this.
    /// Do not fall through to adoptOrMint's fresh UUID.
    package static func persisted(
        configured: String,
        nodeIDFilePath: String = persistedPath
    ) -> String? {
        if let configured = canonical(configured) {
            return configured
        }
        if let onDisk = try? String(contentsOfFile: nodeIDFilePath, encoding: .utf8),
           let persisted = canonical(onDisk) {
            return persisted
        }
        return nil
    }

    /// `persisted` plus the mint — built ON `persisted` so the launch
    /// argument and the scanner's live/orphan verdict can never disagree
    /// about which DB loads.
    package static func adoptOrMint(configured: String) -> String {
        persisted(configured: configured) ?? UUID().uuidString
    }
}
