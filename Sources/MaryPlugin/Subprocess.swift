//
//  Subprocess.swift
//  MaryBrain
//
//  Async Process wrapper shared by Skill bindings and the script runner. Timeouts
//  terminate the child; task cancellation kills it — a barge-in mid-script
//  must never leak a 30-second osascript.
//
//  THE FAILURE THAT DEFEATED EVERY DEADLINE ABOVE THIS FILE. The termination
//  handler used to call `readToEnd()` on the pipe, and `readToEnd` waits for
//  EOF — which on a pipe means every WRITER has closed it, not just the child
//  we spawned. A child that spawns its own child hands the write end straight
//  to the grandchild: `zsh -c "… &"`, `osascript` running `do shell script`,
//  `claude -p` starting a build. So the child exited, the termination handler
//  fired, the read parked forever, and the continuation was never resumed.
//  The watchdog could not rescue it — it guarded on `process.isRunning`, which
//  is already false once the child is gone, so it returned without marking a
//  timeout and without resolving anybody.
//
//  Measured on this machine before the fix: `zsh -c "echo hi; (sleep 60 &);
//  exit 0"` under a TWO SECOND timeout never returned at all; the caller was
//  still parked when the grandchild's sixty seconds ran out. Every AppleScript
//  and shell call in the app is bounded by this function, so the standing
//  claim that "AppleScript is hard-capped at 30 s" was false for exactly the
//  scripts that shell out. It is true now.
//
//  THE SECOND FAILURE, same handler, different victim: `readToEnd()` also
//  RACED the readability handler. Both read the same descriptor from different
//  queues, so the trailing read routinely came back empty because the
//  readability handler had already taken the bytes — and `finish` then
//  snapshotted `data` and resumed BEFORE that handler's append landed. That is
//  `SubshellSafetyTests.shellRunsInCodingProjectRoot` failing once in 48
//  full-suite runs with a real `pwd` returning empty output.
//
//  Both are closed the same way: nothing on the resolve path may block on the
//  pipe, and nothing may read it outside the accumulator's lock. Bytes are
//  taken with a non-blocking drain (`PipeDrain`), and the deadline resumes the
//  continuation itself rather than asking the process for permission first.
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

    /// SIGTERM, then SIGKILL this many seconds later. A child that ignores the
    /// polite signal still dies; a child that handles it gets a moment to.
    public static let escalationGrace: TimeInterval = 2

    /// One second past the SIGKILL (2 + 1). A cancel normally unwinds the
    /// instant the child dies and the termination handler resolves with the
    /// partial output — but a child nobody can kill (uninterruptible sleep on
    /// a stalled mount) would otherwise park the CALLER forever, which is the
    /// same shape of hang this file exists to end. Computed so the `+ 1`
    /// coupling survives a per-call grace (see `run`'s parameter).
    public static var cancelUnwind: TimeInterval { escalationGrace + 1 }

    /// Run to completion with a timeout, off the cooperative pool.
    ///
    /// `escalationGrace` is per-call injection (parameter-with-default, the
    /// repo's seam style — a settable static would be process-global state
    /// racing every concurrent caller): tests stretch it to prove the
    /// DEADLINE released the caller rather than the SIGKILL ladder, and
    /// production callers never pass it.
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
        // From here on every read of this descriptor is our own non-blocking
        // `read(2)`. A blocking one — `readToEnd`, `availableData` — is the bug
        // in the header, and O_NONBLOCK makes writing one again impossible
        // rather than merely discouraged.
        PipeDrain.makeNonBlocking(pipe.fileHandleForReading)

        let state = OutputAccumulator(
            reading: pipe.fileHandleForReading, timeout: timeout,
            escalationGrace: escalationGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Parked in the accumulator, not captured per-handler: the
                // watchdog now resumes it too, and it must be able to do that
                // without the termination handler ever having run.
                state.attach(continuation: continuation)

                // Drain incrementally — a full pipe would deadlock the child.
                pipe.fileHandleForReading.readabilityHandler = { _ in state.drain() }

                process.terminationHandler = { finished in
                    state.noteExit(status: finished.terminationStatus)
                }

                // Attach BEFORE run so onCancel can always reach the child;
                // a cancel that lands pre-run sees isRunning == false and the
                // checkCancellation above prevents spawning into a dead task.
                state.attach(process: process)

                do {
                    try process.run()
                } catch {
                    state.fail(error)
                    return
                }
                if Task.isCancelled {
                    state.terminateOnCancel()
                }
                state.armWatchdog()
            }
        } onCancel: {
            // A barge-in/supersede mid-script must never leak a 30-second
            // osascript: SIGTERM now, SIGKILL if it lingers, and an unwind
            // backstop so the caller is released even if neither lands.
            state.terminateOnCancel()
        }
    }
}

/// Non-blocking pipe reads — the only kind either subprocess path in this
/// module is allowed to make.
///
/// THE FAILURE THIS PREVENTS is the one in `Subprocess.swift`'s header and in
/// `CodingAgentManager.spawn`: `readToEnd()` waits for EOF, EOF means every
/// writer closed, and a grandchild that inherited the write end is a writer we
/// never spawned and cannot see. Reading only what the kernel already holds
/// asks nothing of the grandchild.
public enum PipeDrain {

    /// A pipe buffer is 64 KB, so one buffer of that size empties a full one
    /// in a single syscall.
    private static let chunkBytes = 65_536

    /// 64 × 64 KB = 4 MB per drain — four times the megabyte the accumulator
    /// will retain. A writer that can outrun that will not be caught by
    /// reading harder; the cap is here so a firehose cannot pin the lock this
    /// runs under (in `CodingAgentManager` that lock orders every session).
    private static let maxChunksPerDrain = 64

    public static func makeNonBlocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { return }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Everything the kernel is already holding, and not one byte more.
    /// `atEOF` means every writer has closed — including any grandchild.
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
            // EAGAIN/EWOULDBLOCK: drained. Anything else: the descriptor is
            // gone, and there is nothing left to wait for either way.
            break
        }
        return (collected, false)
    }
}

/// Lock-guarded accumulation + one-shot continuation resolution, shared
/// between the readability handler (background thread), termination handler,
/// the timeout watchdog, and the cancellation unwind.
///
/// THE LOCK ORDERS THE READS, not just the appends. Every read of the pipe
/// happens inside it, so the trailing read on the exit path cannot overtake a
/// readability handler that has already taken bytes but not yet appended them
/// — the interleaving that returned an empty `pwd`.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let reading: FileHandle
    private let timeout: TimeInterval
    /// Per-call SIGTERM→SIGKILL grace — `Subprocess.escalationGrace` unless
    /// the caller injected one (tests stretch it; see `Subprocess.run`).
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

    /// The readability handler's whole body.
    func drain() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        let read = PipeDrain.availableBytes(reading)
        appendLocked(read.data)
        lock.unlock()
        if read.atEOF { stopReading() }
    }

    /// Cap retained output at 1 MB — spoken summaries never need more. The
    /// READ that produced this chunk is never skipped, cap or no cap: stop
    /// reading and the child blocks on a full pipe, which is the deadlock the
    /// incremental drain exists to prevent.
    ///
    /// The chunk is trimmed to the remaining budget rather than dropped whole,
    /// so the cap is a BOUND. The old `if data.count < cap { append(chunk) }`
    /// let one last chunk cross it, and a chunk is now up to `PipeDrain`'s
    /// 4 MB per drain rather than one 64 KB `availableData`.
    private func appendLocked(_ chunk: Data) {
        let remaining = 1_048_576 - data.count
        guard remaining > 0 else { return }
        data.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
    }

    /// A dispatch read source stays hot at EOF, so a child that closes stdout
    /// and then keeps running would spin a core until it exited. Cleared off
    /// the FileHandle's own queue — setting the handler from inside itself can
    /// deadlock against that queue.
    private func stopReading() {
        DispatchQueue.global().async { [reading] in reading.readabilityHandler = nil }
    }

    func noteExit(status: Int32) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        appendLocked(PipeDrain.availableBytes(reading).data)
        resolved = true
        // `String(decoding:)` rather than `String(data:encoding:)`: the 1 MB
        // cap can cut mid-UTF-8-sequence, and the old `?? ""` threw away the
        // whole megabyte when it did. Lose one character instead.
        let output = String(decoding: data, as: UTF8.self)
        let expired = timedOutAfter
        lock.unlock()
        if let expired {
            deliver(.failure(Subprocess.SubprocessError.timedOut(expired)))
        } else {
            deliver(.success(Subprocess.Result(exitCode: status, output: output)))
        }
    }

    /// Armed after a successful `run()`. Held as a cancellable work item so a
    /// fast command doesn't leave this accumulator (and its megabyte, and the
    /// Process) pinned on a global queue until a 300-second deadline elapses.
    func armWatchdog() {
        let item = DispatchWorkItem { [weak self] in self?.timeOut() }
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        watchdog = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// THE DEADLINE IS THE CALLER'S GUARANTEE, so it resumes the continuation
    /// itself and kills afterwards. The old order — terminate, then wait for
    /// the termination handler to resolve — made the effective cap `timeout`
    /// plus however long the child took to die, and no cap at all once the
    /// termination handler could block.
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

    /// Task cancellation: terminate the child (SIGTERM), escalate to SIGKILL
    /// after the grace — the same ladder as the timeout watchdog — and unwind
    /// the caller regardless. Safe to call from any thread; no-op when the
    /// process already exited, never attached, or the call already resolved.
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

    /// Only reached when the child outlived SIGKILL — normally the termination
    /// handler has long since resolved with the partial output.
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
        // Strong capture for the length of the grace: a weakly-held Process
        // that deallocated in between would silently skip the SIGKILL, which
        // is the half of the ladder that handles a child ignoring SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + escalationGrace) {
            guard child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    /// Teardown then resume, and NEVER while holding `lock`: clearing
    /// `readabilityHandler` can wait on the FileHandle's own queue, and a
    /// handler already running there is waiting on `lock`.
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
