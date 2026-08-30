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
        case seer = "Seer"
        case totem = "Totem"
        case fleet = "Fleet"
        package var id: String { rawValue }
    }

    package var kind: Kind
    /// Binary name inside the checkout's .build directory.
    package var executableName: String
    /// Absolute, tilde-expanded checkout root. Children run with this as cwd
    /// so each server's own `.env` loads (Seer needs Supabase keys from it).
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

    /// Seer: HTTP API on `port`, gRPC mothership (which Totem dials) on
    /// `grpcPort`. The mothership is always on — `--enable-totems` no longer
    /// exists as a flag; don't pass it.
    package static func seer(checkoutPath: String, port: Int, grpcPort: Int) -> ServerSpec {
        ServerSpec(
            kind: .seer,
            executableName: "seer-server",
            checkoutPath: expand(checkoutPath),
            arguments: [
                "--host", "127.0.0.1",
                "--port", String(port),
                "--grpc-port", String(grpcPort),
            ],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    /// Totem: HTTP `port`, gRPC `grpcPort`, dials Seer. nodeID pins table-<uuid>.
    /// graphBackend pinned — mlx without metallib degrades to keyword-only.
    package static func totem(
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
            kind: .totem,
            executableName: "totem",
            checkoutPath: expand(checkoutPath),
            arguments: arguments,
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    /// Fleet: HTTP `/health` on `port`, FleetLoRA gRPC on `grpcPort`. Pulls
    /// training corpora from Totem's direct gRPC.
    package static func fleet(
        checkoutPath: String,
        port: Int,
        grpcPort: Int,
        totemGRPCPort: Int
    ) -> ServerSpec {
        ServerSpec(
            kind: .fleet,
            executableName: "fleet",
            checkoutPath: expand(checkoutPath),
            arguments: [
                "serve",
                "--port", String(port),
                "--grpc-port", String(grpcPort),
                "--totem-host", "127.0.0.1",
                "--totem-grpc-port", String(totemGRPCPort),
            ],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!
        )
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Defaults (overridden by ConfigService in the app)

    package enum Defaults {
        static let legacySeerCheckoutPath = "~/Documents/projects/seer/Seer"
        package static let seerCheckoutPath = "~/Documents/rao/repositories/Seer"
        package static let totemCheckoutPath = "~/Documents/rao/repositories/Totem"
        package static let seerPort = 8080
        package static let seerGRPCPort = 9091
        package static let totemPort = 8081
        package static let totemGRPCPort = 9090
        package static let totemGraphBackend = "mistral"
        package static let fleetCheckoutPath = "~/Documents/rao/repositories/Fleet"
        package static let fleetPort = 8083
        package static let fleetGRPCPort = 9093
        package static let seerEmail = "admin@seer.social"
        package static let seerPassword = "cogqab-jazhEv-5rudhi"

        /// Retire the former machine-local default without disturbing a
        /// genuinely custom checkout selected in Settings.
        package static func migratedSeerCheckoutPath(_ path: String) -> String {
            let expandedPath = ServerSpec.expand(path)
            let expandedLegacyPath = ServerSpec.expand(legacySeerCheckoutPath)
            return expandedPath == expandedLegacyPath ? seerCheckoutPath : path
        }
    }
}

/// Node UUID is the DB identity. Config → persisted node-id → mint. Never mint over existing.
package enum TotemNodeIdentity {
    static var persistedPath: String {
        ("~/Documents/totem-db/node-id" as NSString).expandingTildeInPath
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
