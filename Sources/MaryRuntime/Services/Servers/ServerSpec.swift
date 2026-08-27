//
//  ServerSpec.swift
//  Mary
//
//  Pure description of one local server Mary manages (no Process, no IO) —
//  what to launch, where, with which arguments, and how to health-check it.
//  LocalStackManager does the spawning; keeping this value type side-effect
//  free makes argument building and binary resolution unit-testable.
//

import Foundation

package struct ServerSpec: Sendable, Equatable, Identifiable {

    package enum Kind: String, Sendable, CaseIterable, Identifiable {
        case seer = "Seer"
        case totem = "Totem"
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

    /// Totem: HTTP on `port`, direct gRPC (Mary's Conduit line) on
    /// `grpcPort`, dialing Seer's mothership. `nodeID` pins the totem identity
    /// so the same DB (`~/Documents/totem-db/table-<nodeID>`) loads every
    /// launch; empty means Totem uses/creates its own persisted node-id.
    /// `graphBackend` is pinned because Totem's `mlx` default silently
    /// degrades to keyword-only extraction when the build lacks a metallib.
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

/// The totem node UUID IS the database identity (`table-<uuid>` on disk), so
/// Mary must never mint a fresh one while a persisted identity exists —
/// that would silently orphan the whole DB. Resolution order: explicit config
/// → Totem's own persisted `~/Documents/totem-db/node-id` → fresh mint.
package enum TotemNodeIdentity {
    static var persistedPath: String {
        ("~/Documents/totem-db/node-id" as NSString).expandingTildeInPath
    }

    /// THE acceptance rule, spelled once: a node identity is a UUID,
    /// canonicalized through `UUID.uuidString` (uppercase) so config, the
    /// node-id file and on-disk DB names compare equal however they were
    /// cased. Anything else is nil — a value the server would never load
    /// must fall through its tier, not ride along verbatim.
    package static func canonical(_ value: String) -> String? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString
    }

    /// The identity that already exists, or nil — the disk scanner labels DBs
    /// live/orphaned against this, and letting it fall through to
    /// `adoptOrMint`'s fresh UUID would invent a node no DB has ever belonged
    /// to and mark every real one orphaned. Both tiers apply `canonical` —
    /// the rule the server loads by — so a non-UUID config falls to the file
    /// and a corrupt file falls to nil, never into the live-node election.
    /// `nodeIDFilePath` is injectable so the scanner can resolve inside a
    /// test-fixture root; production callers take the default.
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
