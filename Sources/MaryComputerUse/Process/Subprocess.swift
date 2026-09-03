//
//  Subprocess.swift
//  MaryComputerUse
//
//  WHAT: Async Process wrapper for Skill bindings and the script runner.
//  IN:   adapters / script runner
//  OUT:  PipeDrain / OutputAccumulator
//  PIN:  Timeouts terminate; cancel kills. Never block on the pipe (no
//        readToEnd). Deadline resumes the continuation itself.
//

import Foundation

public enum Subprocess {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var output: String
    }

    enum SubprocessError: LocalizedError {
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "The command didn't finish within \(Int(seconds)) seconds."
            }
        }
    }

    /// SIGTERM, then SIGKILL this many seconds later.
    public static let escalationGrace: TimeInterval = 2

    /// One second past SIGKILL. Unwinds the caller even if the child cannot be killed.
    public static var cancelUnwind: TimeInterval { escalationGrace + 1 }

    /// Run to completion with a timeout. Tests may stretch `escalationGrace`; production never passes it.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 60,
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        escalationGrace: TimeInterval = Subprocess.escalationGrace
    ) async throws -> Result {
        try Task.checkCancellation()
        let tool = (executable as NSString).lastPathComponent
        // The TOOL and how many arguments, never the arguments themselves —
        // a path or a commit message is content, and content stays out.
        ComputerUseMonitor.shared.note(
            lane: .process, act: "processStart",
            detail: "\(tool) (\(arguments.count) args)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Non-blocking reads only. O_NONBLOCK makes a blocking readToEnd impossible.
        PipeDrain.makeNonBlocking(pipe.fileHandleForReading)

        let state = OutputAccumulator(
            reading: pipe.fileHandleForReading, timeout: timeout,
            escalationGrace: escalationGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Parked in the accumulator so the watchdog can resume without the termination handler.
                state.attach(continuation: continuation)

                // Drain incrementally — a full pipe would deadlock the child.
                pipe.fileHandleForReading.readabilityHandler = { _ in state.drain() }

                process.terminationHandler = { finished in
                    ComputerUseMonitor.shared.note(
                        lane: .process, act: "processExit",
                        detail: "\(tool) status \(finished.terminationStatus)")
                    state.noteExit(status: finished.terminationStatus)
                }

                // Attach before run so onCancel can always reach the child.
                state.attach(process: process)

                do {
                    try process.run()
                } catch {
                    ComputerUseMonitor.shared.note(
                        lane: .process, refused: "processStart",
                        reason: .processLaunchFailed(tool))
                    state.fail(error)
                    return
                }
                if Task.isCancelled {
                    state.terminateOnCancel()
                }
                state.armWatchdog()
            }
        } onCancel: {
            // Barge-in must not leak a 30s osascript: SIGTERM, then SIGKILL, then unwind.
            state.terminateOnCancel()
        }
    }
}

/// Non-blocking pipe reads — the only kind either subprocess path may make.
/// PIN: readToEnd waits for every writer including grandchildren we cannot see.
public enum PipeDrain {

    /// 64 KB — one syscall empties a full pipe buffer.
    private static let chunkBytes = 65_536

    /// 4 MB per drain so a firehose cannot pin the accumulator lock.
    private static let maxChunksPerDrain = 64

    public static func makeNonBlocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { return }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// What the kernel already holds. `atEOF` = every writer closed, including grandchildren.
    public static func availableBytes(_ handle: FileHandle) -> (data: Data, atEOF: Bool) {
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { return (Data(), true) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        for _ in 0..<maxChunksPerDrain {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, chunkBytes)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { return (collected, true) }
            if errno == EINTR { continue }
            // EAGAIN/EWOULDBLOCK: drained. Anything else: descriptor gone.
            break
        }
        return (collected, false)
    }
}

/// Lock-guarded accumulation + one-shot continuation. Shared by readability,
/// termination, watchdog, and cancel unwind. PIN: the lock orders pipe reads.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let reading: FileHandle
    private let timeout: TimeInterval
    /// Per-call SIGTERM→SIGKILL grace. Tests stretch it; see Subprocess.run.
    private let escalationGrace: TimeInterval
    private var data = Data()
    private var timedOutAfter: TimeInterval?
    private var resolved = false
    private var process: Process?
    private var continuation: CheckedContinuation<Subprocess.Result, Error>?
    private var watchdog: DispatchWorkItem?

    public init(
        reading: FileHandle, timeout: TimeInterval,
        escalationGrace: TimeInterval = Subprocess.escalationGrace
    ) {
        self.reading = reading
        self.timeout = timeout
        self.escalationGrace = escalationGrace
    }

    func attach(continuation: CheckedContinuation<Subprocess.Result, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func attach(process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    /// Readability handler body.
    func drain() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        let read = PipeDrain.availableBytes(reading)
        appendLocked(read.data)
        lock.unlock()
        if read.atEOF { stopReading() }
    }

    /// Cap retained output at 1 MB. Never skip the read — a full pipe deadlocks the child.
    private func appendLocked(_ chunk: Data) {
        let remaining = 1_048_576 - data.count
        guard remaining > 0 else { return }
        data.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
    }

    /// Clear the handler off the FileHandle's queue — setting it from inside itself can deadlock.
    private func stopReading() {
        DispatchQueue.global().async { [reading] in reading.readabilityHandler = nil }
    }

    func noteExit(status: Int32) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        appendLocked(PipeDrain.availableBytes(reading).data)
        resolved = true
        // String(decoding:) — a mid-UTF-8 cap must not throw away the whole megabyte.
        let output = String(decoding: data, as: UTF8.self)
        let expired = timedOutAfter
        lock.unlock()
        if let expired {
            deliver(.failure(Subprocess.SubprocessError.timedOut(expired)))
        } else {
            deliver(.success(Subprocess.Result(exitCode: status, output: output)))
        }
    }

    /// Cancellable work item so a fast command does not pin this accumulator until timeout.
    func armWatchdog() {
        let item = DispatchWorkItem { [weak self] in self?.timeOut() }
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        watchdog = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Deadline resumes the continuation, then kills. Do not wait on termination.
    private func timeOut() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        timedOutAfter = timeout
        resolved = true
        let child = process
        lock.unlock()
        deliver(.failure(Subprocess.SubprocessError.timedOut(timeout)))
        escalate(child)
    }

    /// SIGTERM, then SIGKILL after grace, then unwind. No-op if already resolved.
    func terminateOnCancel() {
        lock.lock()
        let child = process
        let alreadyDone = resolved
        lock.unlock()
        guard !alreadyDone else { return }
        escalate(child)
        DispatchQueue.global().asyncAfter(deadline: .now() + escalationGrace + 1) { [weak self] in
            self?.unwindCancellation()
        }
    }

    /// Reached only if the child outlived SIGKILL.
    private func unwindCancellation() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        lock.unlock()
        deliver(.failure(CancellationError()))
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        lock.unlock()
        deliver(.failure(error))
    }

    private func escalate(_ child: Process?) {
        guard let child, child.isRunning else { return }
        child.terminate()
        // Strong capture for the grace: a weakly-held Process would skip SIGKILL.
        DispatchQueue.global().asyncAfter(deadline: .now() + escalationGrace) {
            guard child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    /// Teardown then resume, never while holding `lock` (handler vs FileHandle queue deadlock).
    private func deliver(_ result: Swift.Result<Subprocess.Result, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        let pending = watchdog
        watchdog = nil
        lock.unlock()
        pending?.cancel()
        reading.readabilityHandler = nil
        switch result {
        case .success(let value): waiting?.resume(returning: value)
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }
}
