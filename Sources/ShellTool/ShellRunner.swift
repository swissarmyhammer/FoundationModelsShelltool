// `ShellRunner` — spawns and supervises one `sh -c {command}` child.
//
// The child is placed in its OWN process group (`platformOptions.processGroupID
// = 0`, which swift-subprocess maps to `POSIX_SPAWN_SETPGROUP` +
// `posix_spawnattr_setpgroup(0)` on Darwin), so the child's pid equals its
// process-group id. Timeout, external kill, and cancellation therefore
// `killpg(pid, SIGKILL)` the whole group and take down any grandchildren the
// command backgrounded (risk plan §7.1). Reaping of the direct child is handled
// by swift-subprocess's `reapProcess`, which runs on every return path of its
// `run(...)`; the runner only has to guarantee the group is killed so that
// `run` can return (via a `defer`'d group-kill and an `onCancel` group-kill).
//
// Output recording is incremental, not batch-at-exit: the two stream readers
// (stdout, stderr) each funnel their raw chunks into one shared `AsyncStream`,
// and a single consumer task (`consume(_:state:commandID:maxSize:)`) drains
// that stream strictly in arrival order, extracting each chunk's newly
// completed lines from a private `OutputBuffer` and flushing them to
// `ShellState.appendLines` before looking at the next chunk. Funneling through
// one consumer — rather than having each stream reader extract-and-flush
// through a shared actor directly — is deliberate: a Swift actor is reentrant
// across suspension points, and its mailbox order across two different
// callers is not documented FIFO, so two producers each independently calling
// `await state.appendLines(...)` could have their flushes land out of arrival
// order. A single sequential consumer has no such race: only it ever touches
// the buffer or calls `appendLines`, one call at a time, in the order it
// dequeues chunks from the stream.

import Foundation
import Subprocess
import Synchronization
import System

/// Executes a single shell command as an `sh -c` child, streaming its output
/// into the shared `ShellState` log and enforcing an optional timeout.
struct ShellRunner {
    /// The default captured-output cap in bytes (10 MiB), shared across
    /// stdout+stderr — parity with the Rust tool's `MAX_OUTPUT_SIZE`.
    static let defaultMaxOutputSize = 10 * 1024 * 1024

    /// The history actor this runner records bookkeeping and output into.
    let state: ShellState

    /// Total captured-output cap in bytes, shared across stdout+stderr. Defaults
    /// to `defaultMaxOutputSize`; injectable so tests can exercise truncation
    /// without generating 10 MiB of output.
    var maxOutputSize: Int = ShellRunner.defaultMaxOutputSize

    /// The process-group registry the spawned child is registered into for the
    /// duration of the run and deregistered from on the `defer` teardown site
    /// below — the backstop `ProcessRegistry.global`'s `atexit` sweep protects
    /// (see that property's doc comment for the "normal process exit only"
    /// limitation on what it can catch). Defaults to `ProcessRegistry.global`;
    /// tests that need to observe or sweep registry state should inject a
    /// private `ProcessRegistry()` instead (see `ProcessRegistry.global`'s doc
    /// comment for why).
    var registry: ProcessRegistry = .global

    /// One command execution request.
    struct Request: Sendable {
        /// The command string passed to `sh -c`.
        var command: String
        /// Working directory; `nil` inherits the calling process's directory.
        var workingDirectory: String?
        /// Environment variables layered on top of the inherited environment.
        var environment: [String: String]
        /// Optional wall-clock timeout; `nil` means no timeout is applied.
        var timeout: Duration?

        /// Create a shell execution request.
        ///
        /// - Parameters:
        ///   - command: the command string passed to `sh -c`.
        ///   - workingDirectory: working directory; `nil` inherits the calling
        ///     process's directory.
        ///   - environment: environment variables layered on top of the
        ///     inherited environment.
        ///   - timeout: optional wall-clock timeout; `nil` means no timeout is
        ///     applied.
        init(
            command: String,
            workingDirectory: String? = nil,
            environment: [String: String] = [:],
            timeout: Duration? = nil
        ) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.timeout = timeout
        }
    }

    /// The result of a completed run.
    struct Outcome: Sendable {
        /// The command id assigned by `ShellState.startCommand`.
        var commandID: Int
        /// Final status (`completed` or `timed_out`).
        var status: CommandStatus
        /// Exit code; signal death and timeout both report `-1` (Rust parity).
        var exitCode: Int
    }

    /// Which concurrent child task in `run`'s task group just completed: a
    /// stream reader reaching EOF, the incremental-flush consumer draining and
    /// sealing the buffer, or the optional timeout timer elapsing.
    private enum BodyEvent: Sendable {
        case streamFinished
        case consumerFinished
        case timerFinished
    }

    /// One raw chunk read from a child's stdout or stderr, tagged by stream
    /// and funneled through a single `AsyncStream` so `consume(_:state:
    /// commandID:maxSize:)` extracts and flushes completed lines strictly in
    /// arrival order (see the file header).
    private struct StreamChunk: Sendable {
        /// Whether `bytes` came from stdout (`true`) or stderr (`false`).
        let isStdout: Bool
        /// The raw bytes read from the stream.
        let bytes: [UInt8]
    }

    /// Run `request` to completion, returning its outcome.
    ///
    /// The command-length (≤ 256 KiB) and env-value (≤ 1024 chars) limits are
    /// **not** re-checked here: they are `ShellPolicy`'s responsibility
    /// (`check(command:)` / `check(environment:)`), which the caller runs before
    /// `run`. The runner accepts pre-validated input and does not duplicate those
    /// limits — the only cap it owns is the captured-output size (`maxOutputSize`).
    func run(_ request: Request) async throws -> Outcome {
        let commandID = await state.startCommand(request.command)

        let config = Configuration(
            executable: .path(FilePath("/bin/sh")),
            arguments: ["-c", request.command],
            environment: Self.environment(overriding: request.environment),
            workingDirectory: request.workingDirectory.map { FilePath($0) },
            platformOptions: Self.ownProcessGroupOptions()
        )

        let pidBox = Mutex<pid_t>(0)
        let timeout = request.timeout
        let st = state
        let maxSize = maxOutputSize
        let reg = registry

        let result = try await withTaskCancellationHandler {
            try await Subprocess.run(
                config, input: .none, output: .sequence, error: .sequence
            ) { execution in
                let pid = execution.processIdentifier.value
                pidBox.withLock { $0 = pid }
                await st.registerProcess(commandID: commandID, pid: pid)
                reg.register(pid)
                // Guaranteed teardown on EVERY body exit path (normal, timeout,
                // error): group-kill so any backgrounded grandchildren die and
                // the library's reap can complete. Killing an already-dead group
                // is a harmless ESRCH. Also deregister from the process-group
                // registry — the run's own teardown just did the real work
                // `sweep(_:)` exists to backstop, so there is nothing left here
                // for a subsequent sweep to (harmlessly) re-kill.
                defer {
                    _ = killpg(pid, SIGKILL)
                    reg.deregister(pid)
                }

                return try await Self.waitForCompletion(
                    stdout: execution.standardOutput,
                    stderr: execution.standardError,
                    state: st,
                    commandID: commandID,
                    maxSize: maxSize,
                    timeout: timeout,
                    pid: pid
                )
            }
        } onCancel: {
            // External cancellation: kill the group immediately so the child's
            // pipes close, the library unblocks the body, and `run` returns to
            // reap the child.
            let pid = pidBox.withLock { $0 }
            if pid != 0 { _ = killpg(pid, SIGKILL) }
        }

        let (status, exitCode) = Self.finalizeResult(
            timedOut: result.closureResult, terminationStatus: result.terminationStatus)

        // Atomic transition: only finalize if still running, so a concurrent
        // `kill process` op that already marked the record `.killed` is not
        // clobbered (the check and write happen in one `ShellState` hop).
        await state.completeIfRunning(commandID: commandID, status: status, exitCode: exitCode)

        return Outcome(commandID: commandID, status: status, exitCode: exitCode)
    }

    /// Number of output streams a child produces (stdout + stderr) — the
    /// count `waitForCompletion` waits to see reach EOF before closing the
    /// chunk stream, so the consumer can drain its last chunks and seal the
    /// buffer.
    private static let outputStreamCount = 2

    /// Run the output-streaming task group to completion for one child: the
    /// two stream readers (`stdout`, `stderr`) funnel raw chunks into a
    /// shared `AsyncStream`, a single consumer task drains and flushes them
    /// to `state.appendLines` in arrival order (see the file header), and an
    /// optional timer kills `pid`'s process group if `timeout` elapses first.
    /// Returns once both streams have reached EOF and the consumer has
    /// finished sealing the buffer — only then is any still-pending timer
    /// cancelled (a post-EOF race against the timeout, matching `run`'s
    /// existing semantics) — reporting whether the timer fired first.
    private static func waitForCompletion(
        stdout: SubprocessOutputSequence,
        stderr: SubprocessOutputSequence,
        state: ShellState,
        commandID: Int,
        maxSize: Int,
        timeout: Duration?,
        pid: pid_t
    ) async throws -> Bool {
        let timedOutFlag = Mutex<Bool>(false)
        let (chunkStream, chunkContinuation) = AsyncStream<StreamChunk>.makeStream()
        try await withThrowingTaskGroup(of: BodyEvent.self) { group in
            group.addTask {
                await Self.drain(stdout, isStdout: true, into: chunkContinuation)
                return .streamFinished
            }
            group.addTask {
                await Self.drain(stderr, isStdout: false, into: chunkContinuation)
                return .streamFinished
            }
            group.addTask {
                try await Self.consume(
                    chunkStream, state: state, commandID: commandID, maxSize: maxSize)
                return .consumerFinished
            }
            if let timeout {
                group.addTask {
                    if (try? await Task.sleep(for: timeout)) != nil {
                        timedOutFlag.withLock { $0 = true }
                        _ = killpg(pid, SIGKILL)
                    }
                    return .timerFinished
                }
            }

            // Both readers hitting EOF ends the chunk stream (so the
            // consumer can drain the last chunks, seal the buffer, and
            // return); only once the consumer has ALSO finished is there
            // nothing left to wait for — cancelling any still-pending timer
            // at that point (post-stream-EOF races the timeout, matching the
            // existing `run` semantics).
            var streamsDone = 0
            var consumerDone = false
            while let event = try await group.next() {
                switch event {
                case .streamFinished:
                    streamsDone += 1
                    if streamsDone == outputStreamCount { chunkContinuation.finish() }
                case .consumerFinished:
                    consumerDone = true
                case .timerFinished:
                    break
                }
                if streamsDone == outputStreamCount, consumerDone {
                    group.cancelAll()
                    break
                }
            }
        }

        return timedOutFlag.withLock { $0 }
    }

    /// Turn a completed run's timeout flag and termination status into the
    /// `(status, exitCode)` pair `run` records and returns: a timeout always
    /// reports `.timedOut`/`-1` regardless of how the process actually died
    /// (killed by our own `SIGKILL`); otherwise a normal exit reports its own
    /// code and a signal death reports `-1` (Rust parity — both `.completed`).
    private static func finalizeResult(
        timedOut: Bool, terminationStatus: TerminationStatus
    ) -> (status: CommandStatus, exitCode: Int) {
        if timedOut {
            return (.timedOut, -1)
        }
        switch terminationStatus {
        case .exited(let code):
            return (.completed, Int(code))
        case .signaled:
            return (.completed, -1)
        }
    }

    /// Platform options that put the child in its own process group (pgid ==
    /// child pid), so the group-kills above target only this command's tree.
    private static func ownProcessGroupOptions() -> PlatformOptions {
        var options = PlatformOptions()
        options.processGroupID = 0
        return options
    }

    /// Build the child environment: the inherited environment with `overrides`
    /// layered on top (added, not replacing).
    private static func environment(overriding overrides: [String: String]) -> Environment {
        guard !overrides.isEmpty else { return .inherit }
        var updates: [Environment.Key: String?] = [:]
        for (key, value) in overrides {
            if let envKey = Environment.Key(rawValue: key) {
                updates[envKey] = value
            }
        }
        return Environment.inherit.updating(updates)
    }

    /// Drain a subprocess output stream to EOF, tagging each raw byte chunk
    /// with its stream and yielding it into `continuation`. Kept reading past
    /// the buffer's cap so a chunky writer never blocks on a full pipe; the
    /// consumer's `OutputBuffer` simply discards the overflow.
    private static func drain(
        _ sequence: SubprocessOutputSequence, isStdout: Bool, into continuation: AsyncStream<StreamChunk>.Continuation
    ) async {
        do {
            for try await chunk in sequence {
                let bytes = chunk.withUnsafeBytes { Array($0) }
                guard !bytes.isEmpty else { continue }
                continuation.yield(StreamChunk(isStdout: isStdout, bytes: bytes))
            }
        } catch {
            // A read cancelled by the library's termination monitor (an inherited
            // grandchild holding the pipe, or our own group-kill) surfaces as a
            // thrown error; treat it as end-of-stream.
        }
    }

    /// Drain `stream`'s chunks strictly in the order they were yielded,
    /// extracting each chunk's newly completed lines from a private
    /// `OutputBuffer` and flushing them to `state.appendLines` before looking
    /// at the next chunk — no concurrent caller ever touches the buffer or
    /// calls `appendLines`, so nothing can reorder the flushes (see the file
    /// header). Once `stream` ends (both readers at EOF), seals the buffer via
    /// `OutputBuffer.finish()` and flushes its trailing partial line(s) and
    /// truncation-marker/binary-placeholder line.
    private static func consume(
        _ stream: AsyncStream<StreamChunk>, state: ShellState, commandID: Int, maxSize: Int
    ) async throws {
        var buffer = OutputBuffer(maxSize: maxSize)
        for await chunk in stream {
            let lines: [String]
            if chunk.isStdout {
                buffer.appendStdout(chunk.bytes)
                lines = buffer.extractCompletedStdoutLines()
            } else {
                buffer.appendStderr(chunk.bytes)
                lines = buffer.extractCompletedStderrLines()
            }
            guard !lines.isEmpty else { continue }
            if chunk.isStdout {
                try await state.appendLines(commandID: commandID, stdout: lines)
            } else {
                try await state.appendLines(commandID: commandID, stderr: lines)
            }
        }

        let final = buffer.finish()
        guard !final.stdout.isEmpty || !final.stderr.isEmpty else { return }
        try await state.appendLines(commandID: commandID, stdout: final.stdout, stderr: final.stderr)
    }
}
