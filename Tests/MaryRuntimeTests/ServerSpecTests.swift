//
//  ServerSpecTests.swift
//  MaryRuntimeTests
//
//  WHAT: The launch arguments Mary hands each server, and the data roots it
//        expects them to keep — all under ~/Documents/maryOS, one directory
//        per server, and the node-id file read from the same root Thread
//        is launched with.
//  OUT:  ServerSpec.sewn/thread/fleet, ServerSpec.Defaults, ThreadNodeIdentity
//

import Foundation
import Testing
@testable import MaryRuntime

@Suite("ServerSpec data directories")
struct ServerSpecTests {

    @Test func defaultsLiveUnderMaryOS() {
        #expect(ServerSpec.Defaults.sewnDataDir == "~/Documents/maryOS/sewn-db")
        #expect(ServerSpec.Defaults.threadDataDir == "~/Documents/maryOS/thread-db")
        #expect(ServerSpec.Defaults.fleetDataDir == "~/Documents/maryOS/fleet-db")
    }

    @Test func everySpecPassesAnExpandedDataDir() {
        let home = NSHomeDirectory()
        let sewn = ServerSpec.sewn(checkoutPath: "~/x/Sewn", port: 8080, grpcPort: 9091)
        let thread = ServerSpec.thread(
            checkoutPath: "~/x/Thread", port: 8081, grpcPort: 9090,
            mothershipGRPCPort: 9091, nodeID: "", graphBackend: "mistral")
        let fleet = ServerSpec.fleet(
            checkoutPath: "~/x/Fleet", port: 8083, grpcPort: 9093, threadGRPCPort: 9090)

        #expect(value(after: "--data-dir", in: sewn.arguments) == "\(home)/Documents/maryOS/sewn-db")
        #expect(value(after: "--data-dir", in: thread.arguments) == "\(home)/Documents/maryOS/thread-db")
        #expect(value(after: "--data-dir", in: fleet.arguments) == "\(home)/Documents/maryOS/fleet-db")
        #expect(fleet.arguments.first == "serve", "fleet is a subcommand CLI; --data-dir belongs to serve")
    }

    @Test func aCustomDataDirIsExpandedAndForwarded() {
        let spec = ServerSpec.sewn(checkoutPath: "~/x", port: 1, grpcPort: 2, dataDir: "~/elsewhere/sewn")
        #expect(value(after: "--data-dir", in: spec.arguments) == "\(NSHomeDirectory())/elsewhere/sewn")
    }

    @Test func nodeIdentityFollowsTheThreadDataDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mary-thread-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        try id.write(to: root.appendingPathComponent("node-id"), atomically: true, encoding: .utf8)

        #expect(ThreadNodeIdentity.nodeIDFilePath(dataDir: root.path) == root.path + "/node-id")
        #expect(ThreadNodeIdentity.adoptOrMint(configured: "", dataDir: root.path) == id)
        #expect(ThreadNodeIdentity.persisted(configured: "", nodeIDFilePath: root.path + "/node-id") == id)
        // The configured id still wins over the file.
        let configured = UUID().uuidString
        #expect(ThreadNodeIdentity.adoptOrMint(configured: configured, dataDir: root.path) == configured)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
