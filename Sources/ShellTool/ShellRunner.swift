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

    private enum BodyEvent: Sendable {
        case streamFinished
        case timerFinished
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
        let timedOutFlag = Mutex<Bool>(false)
        let timeout = request.timeout
        let st = state

        let result = try await withTaskCancellationHandler {
            try await Subprocess.run(
                config, input: .none, output: .sequence, error: .sequence
            ) { execution in
                let pid = execution.processIdentifier.value
                pidBox.withLock { $0 = pid }
                await st.registerProcess(commandID: commandID, pid: pid)
                // Guaranteed teardown on EVERY body exit path (normal, timeout,
                // error): group-kill so any backgrounded grandchildren die and
                // the library's reap can complete. Killing an already-dead group
                // is a harmless ESRCH.
                defer { _ = killpg(pid, SIGKILL) }

                let collector = OutputCollector(maxSize: maxOutputSize)
                try await withThrowingTaskGroup(of: BodyEvent.self) { group in
                    let out = execution.standardOutput
                    let err = execution.standardError
                    group.addTask { await Self.drain(out, into: collector, isStdout: true); return .streamFinished }
                    group.addTask { await Self.drain(err, into: collector, isStdout: false); return .streamFinished }
                    if let timeout {
                        group.addTask {
                            if (try? await Task.sleep(for: timeout)) != nil {
                                timedOutFlag.withLock { $0 = true }
                                _ = killpg(pid, SIGKILL)
                            }
                            return .timerFinished
                        }
                    }
                    var streamsDone = 0
                    while let event = try await group.next() {
                        if case .streamFinished = event { streamsDone += 1 }
                        if streamsDone == 2 {
                            group.cancelAll()
                            break
                        }
                    }
                }

                // Record whatever was captured (partial output on timeout is
                // still recorded): stdout lines first, then stderr, one shared
                // per-command counter (`ShellState.appendLines`).
                let buffer = await collector.finish()
                try await st.appendLines(
                    commandID: commandID, stdout: buffer.stdoutLines, stderr: buffer.stderrLines)
                return timedOutFlag.withLock { $0 }
            }
        } onCancel: {
            // External cancellation: kill the group immediately so the child's
            // pipes close, the library unblocks the body, and `run` returns to
            // reap the child.
            let pid = pidBox.withLock { $0 }
            if pid != 0 { _ = killpg(pid, SIGKILL) }
        }

        let timedOut = result.closureResult
        let status: CommandStatus
        let exitCode: Int
        if timedOut {
            status = .timedOut
            exitCode = -1
        } else {
            switch result.terminationStatus {
            case .exited(let code):
                exitCode = Int(code)
                status = .completed
            case .signaled:
                exitCode = -1
                status = .completed
            }
        }

        // Atomic transition: only finalize if still running, so a concurrent
        // `kill process` op that already marked the record `.killed` is not
        // clobbered (the check and write happen in one `ShellState` hop).
        await state.completeIfRunning(commandID: commandID, status: status, exitCode: exitCode)

        return Outcome(commandID: commandID, status: status, exitCode: exitCode)
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

    /// Drain a subprocess output stream to EOF, feeding each raw byte chunk into
    /// `collector`. Kept reading past the buffer's cap so a chunky writer never
    /// blocks on a full pipe; the collector simply discards the overflow.
    private static func drain(
        _ sequence: SubprocessOutputSequence, into collector: OutputCollector, isStdout: Bool
    ) async {
        do {
            for try await chunk in sequence {
                let bytes = chunk.withUnsafeBytes { Array($0) }
                guard !bytes.isEmpty else { continue }
                if isStdout {
                    await collector.appendStdout(bytes)
                } else {
                    await collector.appendStderr(bytes)
                }
            }
        } catch {
            // A read cancelled by the library's termination monitor (an inherited
            // grandchild holding the pipe, or our own group-kill) surfaces as a
            // thrown error; treat it as end-of-stream.
        }
    }
}

/// Serializes the two concurrent stream readers' writes into one `OutputBuffer`,
/// so the shared size cap is enforced across stdout and stderr without a data
/// race on the buffer.
private actor OutputCollector {
    private var buffer: OutputBuffer

    init(maxSize: Int) {
        buffer = OutputBuffer(maxSize: maxSize)
    }

    func appendStdout(_ data: [UInt8]) {
        buffer.appendStdout(data)
    }

    func appendStderr(_ data: [UInt8]) {
        buffer.appendStderr(data)
    }

    /// Seal the buffer with a truncation marker (if truncated) and return it.
    func finish() -> OutputBuffer {
        buffer.addTruncationMarker()
        return buffer
    }
}
