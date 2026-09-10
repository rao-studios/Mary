//
//  ProbeServers.swift
//  Mary
//
//  WHAT: Headless LocalStackManager (same as app boot): spawn / health / stop.
//  OUT:  CLI: swift run Mary --probe-servers [--keep|--stop]
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
        let nodeID = ThreadNodeIdentity.adoptOrMint(configured: "")
        print("thread node-id: \(nodeID)")
        ensureDataDirectories([
            ServerSpec.Defaults.sewnDataDir,
            ServerSpec.Defaults.threadDataDir,
            ServerSpec.Defaults.fleetDataDir,
        ])
        await manager.configure([
            .sewn(
                checkoutPath: ServerSpec.Defaults.sewnCheckoutPath,
                port: ServerSpec.Defaults.sewnPort,
                grpcPort: ServerSpec.Defaults.sewnGRPCPort,
                dataDir: ServerSpec.Defaults.sewnDataDir),
            .thread(
                checkoutPath: ServerSpec.Defaults.threadCheckoutPath,
                port: ServerSpec.Defaults.threadPort,
                grpcPort: ServerSpec.Defaults.threadGRPCPort,
                mothershipGRPCPort: ServerSpec.Defaults.sewnGRPCPort,
                nodeID: nodeID,
                graphBackend: ServerSpec.Defaults.threadGraphBackend,
                dataDir: ServerSpec.Defaults.threadDataDir),
            .fleet(
                checkoutPath: ServerSpec.Defaults.fleetCheckoutPath,
                port: ServerSpec.Defaults.fleetPort,
                grpcPort: ServerSpec.Defaults.fleetGRPCPort,
                threadGRPCPort: ServerSpec.Defaults.threadGRPCPort,
                dataDir: ServerSpec.Defaults.fleetDataDir),
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
