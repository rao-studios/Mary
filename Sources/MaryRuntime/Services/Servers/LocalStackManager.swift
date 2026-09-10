//
//  LocalStackManager.swift
//  MaryRuntime
//
//  WHAT: Owns local Sewn + Thread + Fleet: spawn, health, restart, teardown.
//  OUT:  Sendable snapshots + change stream. Process handles stay in the actor.
//  PIN:  Logs to files not pipes (orphan stays adoptable). PID files under
//        Application Support. Healthy-unclaimed = external — do not kill on quit.
//        emergencyStopAllSync via static lock (no actor hop at terminate).
//
//    boot: alive+ours+healthy → adopt; alive+unhealthy → reap; dead → clear
//    spawn order: Sewn mothership, then Thread (dials it)
//

import Foundation
import os

package enum ServerStatus: String, Sendable {
    case notBuilt      // no binary in .build/{release,debug}
    case stopped
    case launching     // spawned, waiting on first healthy /health
    case healthy
    case unhealthy     // process alive (or unknown) but /health failing
    case external      // running fine, but not ours to manage
    case building
}

package struct ServerStatusSnapshot: Sendable, Identifiable, Equatable {
    package var kind: ServerSpec.Kind
    package var status: ServerStatus
    package var pid: Int32?
    package var startedAt: Date?
    package var binaryPath: String?
    var logPath: String
    package var detail: String?

    package var id: String { kind.rawValue }
}

package actor LocalStackManager {
    package init() {}

    /// Owned child pids, readable without an actor hop so the app delegate
    /// can kill them synchronously at quit.
    private static let ownedPids = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    private struct Managed {
        var spec: ServerSpec
        var process: Process?
        package var pid: pid_t?
        package var startedAt: Date?
        package var status: ServerStatus = .stopped
        var adopted = false      // ours from a previous run (no Process handle)
        package var detail: String?
    }

    private var servers: [ServerSpec.Kind: Managed] = [:]
    private var order: [ServerSpec.Kind] = []
    private var pollTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<[ServerStatusSnapshot]>.Continuation] = [:]

    // MARK: - Configuration

    /// (Re)configures the stack. Running servers whose spec is unchanged keep
    /// running; a changed spec applies on next restart.
    package func configure(_ specs: [ServerSpec]) {
        order = specs.map(\.kind)
        for spec in specs {
            if var existing = servers[spec.kind] {
                existing.spec = spec
                servers[spec.kind] = existing
            } else {
                servers[spec.kind] = Managed(spec: spec)
            }
        }
        startPollingIfNeeded()
    }

    // MARK: - Boot

    /// Brings the whole stack up in configured order: reap-or-adopt leftovers
    /// from a previous run, adopt externals, spawn what's missing, and wait
    /// for health. Returns a user-facing error string on failure (nil = up).
    package func ensureRunning() async -> String? {
        var failures: [String] = []
        for kind in order {
            if let failure = await ensureRunning(kind) {
                failures.append(failure)
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func ensureRunning(_ kind: ServerSpec.Kind) async -> String? {
        guard var managed = servers[kind] else { return nil }
        let spec = managed.spec

        // Already ours and alive?
        if let pid = managed.pid, isAlive(pid) {
            return nil
        }

        // A previous Mary run's child, recorded in the pid file?
        if let recordedPid = readPidFile(kind), isAlive(recordedPid) {
            if commandPath(of: recordedPid)?.hasSuffix("/\(spec.executableName)") == true {
                if await checkHealth(spec.healthURL) {
                    managed.pid = recordedPid
                    managed.adopted = true
                    managed.status = .healthy
                    managed.startedAt = nil
                    managed.detail = "adopted from previous run"
                    servers[kind] = managed
                    Self.ownedPids.withLock { _ = $0.insert(recordedPid) }
                    publish()
                    return nil
                }
                // Ours but sick — replace it.
                reap(recordedPid)
            }
            // Alive pid that isn't our binary: stale file, someone else's pid.
            removePidFile(kind)
        } else if readPidFile(kind) != nil {
            removePidFile(kind)
        }

        // Someone else already serves this port (start-sewn-thread.sh)?
        if await checkHealth(spec.healthURL) {
            managed.status = .external
            managed.pid = nil
            managed.detail = "running outside Mary"
            servers[kind] = managed
            publish()
            return nil
        }

        servers[kind] = managed
        return await start(kind)
    }

    /// Reattaches to children a previous Mary run left behind (pid file →
    /// alive → our binary) WITHOUT spawning anything. For teardown paths that
    /// must never bring the stack up first.
    package func adoptExisting() {
        for kind in order {
            guard var managed = servers[kind], managed.pid == nil else { continue }
            guard let recordedPid = readPidFile(kind), isAlive(recordedPid),
                  commandPath(of: recordedPid)?.hasSuffix("/\(managed.spec.executableName)") == true else {
                continue
            }
            managed.pid = recordedPid
            managed.adopted = true
            managed.status = .unhealthy   // unknown until the next poll
            managed.detail = "adopted from previous run"
            servers[kind] = managed
            Self.ownedPids.withLock { _ = $0.insert(recordedPid) }
        }
        publish()
    }

    // MARK: - Start / stop / restart

    /// Spawns the server and waits for /health. Returns error text or nil.
    package func start(_ kind: ServerSpec.Kind) async -> String? {
        guard var managed = servers[kind] else { return "\(kind.rawValue) isn't configured." }
        let spec = managed.spec
        if managed.status == .external { return nil }
        if let pid = managed.pid, isAlive(pid) { return nil }

        guard case .built(let binaryPath, _) = spec.resolveBinary() else {
            managed.status = .notBuilt
            managed.detail = "no binary in \(spec.checkoutPath)/.build — build it first"
            servers[kind] = managed
            publish()
            return "\(kind.rawValue) isn't built yet."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = spec.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.checkoutPath)

        try? FileManager.default.createDirectory(
            atPath: Self.stateDirectory, withIntermediateDirectories: true)
        let logURL = URL(fileURLWithPath: Self.logPath(kind))
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            guard let self else { return }
            Task { await self.childExited(kind, exitCode: status) }
        }

        do {
            try process.run()
        } catch {
            managed.status = .stopped
            managed.detail = "launch failed: \(error.localizedDescription)"
            servers[kind] = managed
            publish()
            return "\(kind.rawValue) failed to launch."
        }

        let pid = process.processIdentifier
        managed.process = process
        managed.pid = pid
        managed.adopted = false
        managed.startedAt = Date()
        managed.status = .launching
        managed.detail = nil
        servers[kind] = managed
        Self.ownedPids.withLock { _ = $0.insert(pid) }
        writePidFile(kind, pid: pid)
        publish()

        // Wait for first health (Sewn validates env, Thread restores its DB).
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if await checkHealth(spec.healthURL) {
                setStatus(kind, .healthy, detail: nil)
                return nil
            }
            // Early exit if the child already died (bad .env → fatalError).
            if !isAlive(pid) {
                setStatus(kind, .stopped, detail: "exited during launch — check \(Self.logPath(kind))")
                return "\(kind.rawValue) exited during launch."
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        setStatus(kind, .unhealthy, detail: "no /health response after 60s")
        return "\(kind.rawValue) didn't become healthy."
    }

    package func stop(_ kind: ServerSpec.Kind) async {
        guard var managed = servers[kind] else { return }
        let ownedHandle = managed.process
        let pids = stopTargets(for: managed)
        if pids.isEmpty {
            if managed.status == .external {
                let port = managed.spec.healthURL.port.map(String.init)
                    ?? managed.spec.healthURL.absoluteString
                managed.detail =
                    "couldn't find \(managed.spec.executableName) listening on \(port)"
                servers[kind] = managed
                publish()
            }
            return
        }

        for pid in pids {
            if ownedHandle != nil, managed.pid == pid {
                ownedHandle?.terminate()
            } else {
                kill(pid, SIGTERM)
            }
            await waitForExit(pid)
            Self.ownedPids.withLock { _ = $0.remove(pid) }
        }

        removePidFile(kind)
        managed.process = nil
        managed.pid = nil
        managed.startedAt = nil
        managed.adopted = false
        managed.status = .stopped
        managed.detail = nil
        servers[kind] = managed
        publish()
    }

    /// Owned pid if we have one; otherwise the listener on the health port
    /// whose path is this spec's binary — the external / script-launched case.
    private func stopTargets(for managed: Managed) -> [pid_t] {
        if let pid = managed.pid, isAlive(pid) {
            return [pid]
        }
        guard let port = managed.spec.healthURL.port else { return [] }
        return StackListener.matching(
            listed: pidsListening(on: port),
            executableName: managed.spec.executableName,
            commandPath: commandPath(of:))
    }

    private func waitForExit(_ pid: pid_t) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, isAlive(pid) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isAlive(pid) { kill(pid, SIGKILL) }
    }

    /// `lsof -t` of TCP LISTEN on `port`. Empty when lsof is missing or
    /// nothing is bound — Stop then leaves a note rather than guessing.
    private func pidsListening(on port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return StackListener.parsePIDs(String(data: data, encoding: .utf8) ?? "")
    }

    package func restart(_ kind: ServerSpec.Kind) async -> String? {
        await stop(kind)
        return await start(kind)
    }

    package func stopAll() async {
        // Reverse order: the node goes down before its mothership.
        for kind in order.reversed() {
            await stop(kind)
        }
    }

    // MARK: - Build on demand

    /// Runs `swift build -c release` in the checkout, then — for a server that
    /// runs models on the GPU — its `build-metallib.sh`, streaming both.
    ///
    /// SWIFTPM HAS NO METAL STEP. Sewn's on-device backend and Fleet's LoRA
    /// decoder both load `mlx.metallib` from beside their binary, and a fresh
    /// `.build/release` has none: the first model load then dies inside MLX
    /// with "Failed to load the default metallib", which is not a Swift error
    /// anything here could catch. Building it is part of building the server.
    /// The stream finishes when both exit; check `snapshot()` after.
    package func build(_ kind: ServerSpec.Kind) -> AsyncStream<String> {
        guard let managed = servers[kind] else {
            return AsyncStream { $0.finish() }
        }
        setStatus(kind, .building, detail: "swift build -c release")
        let checkout = managed.spec.checkoutPath

        return AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "build", "-c", "release"]
            process.currentDirectoryURL = URL(fileURLWithPath: checkout)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = OSAllocatedUnfairLock(initialState: Data())
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines: [String] = buffer.withLock { pending in
                    pending.append(data)
                    var out: [String] = []
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<newline]
                        pending.removeSubrange(pending.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8) { out.append(line) }
                    }
                    return out
                }
                for line in lines { continuation.yield(line) }
            }
            process.terminationHandler = { [weak self] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let ok = finished.terminationStatus == 0
                continuation.yield(ok ? "Build complete." : "Build failed (exit \(finished.terminationStatus)).")
                if ok, let script = Self.metallibScript(in: checkout) {
                    continuation.yield("Compiling mlx.metallib…")
                    let metal = Process()
                    metal.executableURL = URL(fileURLWithPath: "/bin/bash")
                    metal.arguments = [script, "release"]
                    metal.currentDirectoryURL = URL(fileURLWithPath: checkout)
                    metal.standardOutput = FileHandle.nullDevice
                    metal.standardError = FileHandle.nullDevice
                    do {
                        try metal.run()
                        metal.waitUntilExit()
                        continuation.yield(
                            metal.terminationStatus == 0
                                ? "mlx.metallib ready."
                                : "mlx.metallib FAILED — on-device work in this server will abort.")
                    } catch {
                        continuation.yield(
                            "Couldn't run build-metallib.sh: \(error.localizedDescription)")
                    }
                }
                continuation.finish()
                guard let self else { return }
                Task { await self.buildFinished(kind, success: ok) }
            }
            do {
                try process.run()
            } catch {
                continuation.yield("Couldn't run swift build: \(error.localizedDescription)")
                continuation.finish()
                Task { [weak self] in await self?.buildFinished(kind, success: false) }
            }
        }
    }

    /// The checkout's own metallib script, at either place the siblings keep
    /// it. Nil when the server needs no GPU (Thread).
    static func metallibScript(in checkout: String) -> String? {
        for candidate in ["scripts/build-metallib.sh", "build-metallib.sh"] {
            let path = (checkout as NSString).appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func buildFinished(_ kind: ServerSpec.Kind, success: Bool) {
        guard let managed = servers[kind] else { return }
        if managed.pid != nil, managed.status == .building {
            // Shouldn't happen (build while running keeps prior status), but recover.
            setStatus(kind, .healthy, detail: nil)
            return
        }
        switch managed.spec.resolveBinary() {
        case .built:
            setStatus(kind, .stopped, detail: success ? "built — ready to start" : "build failed, older binary present")
        case .notBuilt:
            setStatus(kind, .notBuilt, detail: success ? "build produced no binary?" : "build failed")
        }
    }

    // MARK: - Observation

    package func snapshot() -> [ServerStatusSnapshot] {
        order.compactMap { kind in
            guard let managed = servers[kind] else { return nil }
            var status = managed.status
            if case .notBuilt = managed.spec.resolveBinary(),
               managed.pid == nil, status == .stopped {
                status = .notBuilt
            }
            return ServerStatusSnapshot(
                kind: kind,
                status: status,
                pid: managed.pid,
                startedAt: managed.startedAt,
                binaryPath: {
                    if case .built(let path, _) = managed.spec.resolveBinary() { return path }
                    return nil
                }(),
                logPath: Self.logPath(kind),
                detail: managed.detail
            )
        }
    }

    package func statusStream() -> AsyncStream<[ServerStatusSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish() {
        let current = snapshot()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    // MARK: - Health polling

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        for kind in order {
            guard let managed = servers[kind] else { continue }
            switch managed.status {
            case .healthy, .unhealthy, .external, .launching:
                let healthy = await checkHealth(managed.spec.healthURL)
                if managed.status == .external {
                    if !healthy { setStatus(kind, .stopped, detail: "external server went away") }
                } else if healthy {
                    if managed.status != .healthy { setStatus(kind, .healthy, detail: nil) }
                } else if managed.status == .healthy {
                    setStatus(kind, .unhealthy, detail: "health check failing")
                }
            case .stopped, .notBuilt:
                // A server may appear underneath us (user launched it by hand).
                if managed.pid == nil, await checkHealth(managed.spec.healthURL) {
                    setStatus(kind, .external, detail: "running outside Mary")
                }
            case .building:
                break
            }
        }
    }

    private func checkHealth(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func setStatus(_ kind: ServerSpec.Kind, _ status: ServerStatus, detail: String?) {
        guard var managed = servers[kind] else { return }
        managed.status = status
        managed.detail = detail
        servers[kind] = managed
        publish()
    }

    private func childExited(_ kind: ServerSpec.Kind, exitCode: Int32) {
        guard var managed = servers[kind] else { return }
        if let pid = managed.pid {
            Self.ownedPids.withLock { _ = $0.remove(pid) }
        }
        removePidFile(kind)
        managed.process = nil
        managed.pid = nil
        managed.startedAt = nil
        // Keep .stopped from an intentional stop(); anything else is a crash.
        if managed.status != .stopped {
            managed.status = .stopped
            managed.detail = exitCode == 0
                ? "exited"
                : "exited with status \(exitCode) — see \(Self.logPath(kind))"
        }
        servers[kind] = managed
        publish()
    }

    // MARK: - PID files & process identity

    static var stateDirectory: String {
        ("~/Library/Application Support/Mary/servers" as NSString).expandingTildeInPath
    }

    static func logPath(_ kind: ServerSpec.Kind) -> String {
        "\(stateDirectory)/\(kind.rawValue.lowercased()).log"
    }

    private static func pidPath(_ kind: ServerSpec.Kind) -> String {
        "\(stateDirectory)/\(kind.rawValue.lowercased()).pid"
    }

    private func writePidFile(_ kind: ServerSpec.Kind, pid: pid_t) {
        try? FileManager.default.createDirectory(
            atPath: Self.stateDirectory, withIntermediateDirectories: true)
        try? "\(pid)".write(toFile: Self.pidPath(kind), atomically: true, encoding: .utf8)
    }

    private func readPidFile(_ kind: ServerSpec.Kind) -> pid_t? {
        guard let raw = try? String(contentsOfFile: Self.pidPath(kind), encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private func removePidFile(_ kind: ServerSpec.Kind) {
        try? FileManager.default.removeItem(atPath: Self.pidPath(kind))
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Full executable path of a live process (empty/nil when gone or denied).
    /// The binary-path check is what makes pid reaping safe: pids recycle, and
    /// killing an unverified pid is never acceptable.
    private func commandPath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<20 where isAlive(pid) {
            usleep(100_000)
        }
        if isAlive(pid) { kill(pid, SIGKILL) }
    }

    // MARK: - Quit-time teardown (sync, no actor hop)

    /// Called from applicationWillTerminate: SIGTERM every owned child, give
    /// the group 2 seconds, SIGKILL survivors. Blocking is fine — the app is
    /// already exiting.
    package static func emergencyStopAllSync() {
        let pids = ownedPids.withLock { $0 }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        // Children are gone by our hand — clear their pid files.
        for kind in ServerSpec.Kind.allCases {
            try? FileManager.default.removeItem(atPath: pidPath(kind))
        }
    }
}
