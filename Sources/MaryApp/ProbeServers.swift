//
//  ProbeServers.swift
//  Mary
//
//  Headless exercise of the local server stack from the terminal:
//
//    swift run Mary --probe-servers            spawn → health → stop
//    swift run Mary --probe-servers --keep     spawn → health → leave running
//    swift run Mary --probe-servers --stop     stop whatever a --keep left
//
//  Uses the same LocalStackManager the app boots with, so adopt/reap/external
//  behavior is exactly what the app will do.
//

import Foundation
import MaryRuntime

enum ProbeServers {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-servers")
    }

    static func start() {
        Task.detached {
            let code = await run()
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func run() async -> Int32 {
        let keep = CommandLine.arguments.contains("--keep")
        let stopOnly = CommandLine.arguments.contains("--stop")

        let manager = LocalStackManager()
        let nodeID = TotemNodeIdentity.adoptOrMint(configured: "")
        print("totem node-id: \(nodeID)")
        await manager.configure([
            .seer(
                checkoutPath: ServerSpec.Defaults.seerCheckoutPath,
                port: ServerSpec.Defaults.seerPort,
                grpcPort: ServerSpec.Defaults.seerGRPCPort),
            .totem(
                checkoutPath: ServerSpec.Defaults.totemCheckoutPath,
                port: ServerSpec.Defaults.totemPort,
                grpcPort: ServerSpec.Defaults.totemGRPCPort,
                mothershipGRPCPort: ServerSpec.Defaults.seerGRPCPort,
                nodeID: nodeID,
                graphBackend: ServerSpec.Defaults.totemGraphBackend),
            .fleet(
                checkoutPath: ServerSpec.Defaults.fleetCheckoutPath,
                port: ServerSpec.Defaults.fleetPort,
                grpcPort: ServerSpec.Defaults.fleetGRPCPort,
                totemGRPCPort: ServerSpec.Defaults.totemGRPCPort),
        ])

        if stopOnly {
            await manager.adoptExisting()
            await manager.stopAll()
            printSnapshots(await manager.snapshot())
            return 0
        }

        print("bringing the stack up…")
        let failure = await manager.ensureRunning()
        printSnapshots(await manager.snapshot())
        if let failure {
            print("FAILED: \(failure)")
            return 1
        }
        print("stack is up.")

        if keep {
            print("(left running — stop with --probe-servers --stop, or kill the pids above)")
            return 0
        }

        print("stopping…")
        await manager.stopAll()
        printSnapshots(await manager.snapshot())
        print("done.")
        return 0
    }

    private static func printSnapshots(_ snapshots: [ServerStatusSnapshot]) {
        for snapshot in snapshots {
            var line = "  \(snapshot.kind.rawValue): \(snapshot.status.rawValue)"
            if let pid = snapshot.pid { line += " pid=\(pid)" }
            if let detail = snapshot.detail { line += " (\(detail))" }
            print(line)
        }
    }
}
