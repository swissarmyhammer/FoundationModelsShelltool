import Foundation
import Testing

@testable import ShellTool

/// Behavioral tests for `ShellRunner` — real `sh -c` children spawned into a
/// fresh, temp-rooted `ShellState`.
///
/// These tests run genuine subprocesses (echo, sleep trees, pgrep). Each test
/// that starts a process tree cleans it up (via the runner's own group-kill or
/// an explicit teardown) so nothing leaks between tests.
@Suite struct ShellRunnerTests {

    /// A `ShellRunner` over a `ShellState` rooted in a unique temp directory.
    ///
    /// - Parameter registry: The process-group registry to inject. Defaults to
    ///   a fresh **private** `ProcessRegistry()` (never `.global`) so ordinary
    ///   tests never touch the process-wide instance; pass one explicitly when
    ///   a test needs to observe or sweep its state.
    private func makeRunner(registry: ProcessRegistry = ProcessRegistry()) throws -> (ShellRunner, ShellState, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellrunner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let state = try ShellState(preferredDirectory: tmp.appendingPathComponent(".shell"))
        return (ShellRunner(state: state, registry: registry), state, tmp)
    }

    /// Count live processes whose full command line matches `pattern`, via
    /// `pgrep -f`. Returns 0 when pgrep finds none (exit status 1).
    private func processCount(matching pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// Poll `processCount(matching:)` until it satisfies `predicate` or the
    /// deadline passes; returns the last observed count.
    private func waitForProcessCount(
        matching pattern: String,
        deadline: Duration,
        until predicate: (Int) -> Bool
    ) async -> Int {
        let clock = ContinuousClock()
        let start = clock.now
        var count = processCount(matching: pattern)
        while !predicate(count), clock.now - start < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            count = processCount(matching: pattern)
        }
        return count
    }

    /// Poll `state.listCommands()` for `commandID`'s record until it
    /// satisfies `predicate` or `deadline` passes; returns the last observed
    /// record (`nil` if the id was never started).
    private func waitForRecord(
        in state: ShellState,
        commandID: Int,
        deadline: Duration,
        until predicate: (CommandRecord) -> Bool
    ) async -> CommandRecord? {
        let clock = ContinuousClock()
        let start = clock.now
        var record = await state.listCommands().first { $0.id == commandID }
        while (record.map { !predicate($0) } ?? true), clock.now - start < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            record = await state.listCommands().first { $0.id == commandID }
        }
        return record
    }

    // MARK: - Risk §7.1 spike: process-group kill takes down the whole tree

    /// The load-bearing integration test: a `sh -c 'sleep N & sleep N'` tree
    /// launched with the runner's own-process-group spawn must be entirely
    /// killed when the timeout fires the group-kill — no `sleep` survives.
    @Test func timeoutGroupKillLeavesNoSurvivorsInProcessTree() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A unique sleep duration so pgrep -f matches only this test's tree.
        let marker = Int.random(in: 100_000...999_999)
        let command = "sleep \(marker) & sleep \(marker)"
        let pattern = "sleep \(marker)"

        // Run in the background; the timeout will group-kill the tree.
        let runTask = Task {
            try await runner.run(.init(command: command, timeout: .seconds(2)))
        }

        // The tree must actually come up (both sleeps alive).
        let alive = await waitForProcessCount(
            matching: pattern, deadline: .seconds(1), until: { $0 >= 2 })
        #expect(alive >= 2, "expected the sleep tree to be running, saw \(alive)")

        // The run resolves as timed_out once the timeout fires the group-kill.
        let outcome = try await runTask.value
        #expect(outcome.status == .timedOut)
        #expect(outcome.exitCode == -1)

        // No member of the tree survives the group-kill.
        let survivors = await waitForProcessCount(
            matching: pattern, deadline: .seconds(2), until: { $0 == 0 })
        #expect(survivors == 0, "process-group kill left \(survivors) survivor(s)")
    }

    // MARK: - Default output cap constant (parity with Rust MAX_OUTPUT_SIZE)

    @Test func defaultOutputCapIsTenMiB() {
        #expect(ShellRunner.defaultMaxOutputSize == 10 * 1024 * 1024)
    }

    // MARK: - Echo round-trip and captured output

    @Test func echoRoundTripCapturesOneLineAndExitsZero() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outcome = try await runner.run(.init(command: "echo hi"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 0)

        let lines = try await state.getLines(commandID: outcome.commandID)
        #expect(lines == [LogLine(lineNumber: 1, text: "hi")])
    }

    // MARK: - Exit codes are data, not tool errors

    @Test func zeroExitIsReportedAndSuccessful() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outcome = try await runner.run(.init(command: "exit 0"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 0)
    }

    @Test func nonZeroExitIsReportedAndNotAThrownError() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A non-zero exit is a *successful* call reporting exit_code: 2.
        let outcome = try await runner.run(.init(command: "exit 2"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 2)
    }

    @Test func signalDeathReportsExitCodeMinusOne() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The shell kills itself; termination by signal reports -1 (parity with
        // Rust's `code().unwrap_or(-1)`), and it is not a timeout.
        let outcome = try await runner.run(.init(command: "kill -KILL $$"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == -1)
    }

    // MARK: - Environment layered on top of the inherited environment

    @Test func requestedEnvIsAddedOnTopOfInheritedEnvironment() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // SHELLRUNNER_TEST is injected; HOME is inherited and must survive.
        let outcome = try await runner.run(
            .init(
                command: #"printf '%s|%s' "$SHELLRUNNER_TEST" "${HOME:+haveHOME}""#,
                environment: ["SHELLRUNNER_TEST": "present"]))
        let lines = try await state.getLines(commandID: outcome.commandID)
        #expect(lines == [LogLine(lineNumber: 1, text: "present|haveHOME")])
    }

    // MARK: - Working directory

    @Test func runsInRequestedWorkingDirectory() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let workDir = tmp.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let outcome = try await runner.run(
            .init(command: "/bin/pwd", workingDirectory: workDir.path))
        let lines = try await state.getLines(commandID: outcome.commandID)
        let printed = lines.first?.text ?? "<none>"
        // `/bin/pwd` prints the physical cwd (`/var` → `/private/var` on macOS),
        // so compare both sides symlink-resolved.
        let expected = workDir.resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
        #expect(actual == expected, "pwd printed \(printed); expected \(expected)")
    }

    // MARK: - Output cap: truncation at a line boundary with the marker

    @Test func outputJustOverCapTruncatesAtLineBoundaryWithMarker() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellrunner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try ShellState(preferredDirectory: tmp.appendingPathComponent(".shell"))
        // Small cap (but larger than the ~41-byte marker) so a few dozen short
        // lines exceed it — the cap logic itself is covered exhaustively in
        // OutputBufferTests; here we prove the runner wires truncation + marker
        // through to the log.
        let runner = ShellRunner(state: state, maxOutputSize: 200, registry: ProcessRegistry())

        let outcome = try await runner.run(
            .init(command: "for i in $(seq 1 60); do echo \"line$i\"; done"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 0)

        let lines = try await state.getLines(commandID: outcome.commandID)
        // Truncated at a line boundary (no partial line), with the marker last.
        #expect(lines.first?.text == "line1")
        #expect(!lines.map(\.text).contains("line60"))
        #expect(lines.last?.text == "[Output truncated - exceeded size limit]")
    }

    // MARK: - Binary content placeholder

    @Test func nullByteInOutputYieldsBinaryPlaceholder() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 7 bytes: a b c NUL d e f — the null triggers binary detection.
        let outcome = try await runner.run(.init(command: #"printf 'abc\000def'"#))
        let lines = try await state.getLines(commandID: outcome.commandID)
        #expect(lines == [LogLine(lineNumber: 1, text: "[Binary content: 7 bytes]")])
    }

    // MARK: - Interleaving: incremental flush preserves arrival order, one shared counter

    /// With deliberate gaps between each write (so the two stream readers each
    /// have time to drain and flush before the next write lands), the stored
    /// order matches arrival order exactly — stdout and stderr interleaved, not
    /// grouped. Supersedes the old batch-at-exit "stdout always precedes
    /// stderr" contract (DESIGN_NOTES §8).
    @Test func stdoutAndStderrInterleaveInArrivalOrderWithAlternatingWrites() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let command = """
            printf 'out1\\n'; sleep 0.05
            printf 'err1\\n' >&2; sleep 0.05
            printf 'out2\\n'; sleep 0.05
            printf 'err2\\n' >&2
            """
        let outcome = try await runner.run(.init(command: command))
        let lines = try await state.getLines(commandID: outcome.commandID)
        #expect(lines == [
            LogLine(lineNumber: 1, text: "out1"),
            LogLine(lineNumber: 2, text: "err1"),
            LogLine(lineNumber: 3, text: "out2"),
            LogLine(lineNumber: 4, text: "err2"),
        ])
    }

    // MARK: - Incremental recording: output visible while the command is still running

    @Test func linesAreVisibleInShellStateWhileTheCommandIsStillRunning() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runTask = Task {
            try await runner.run(.init(command: "echo one; sleep 5"))
        }
        defer {
            runTask.cancel()
        }

        // Poll until the emitted line shows up — well before the sleep ends.
        var lines: [LogLine] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while lines.isEmpty, clock.now < deadline {
            lines = try await state.getLines(commandID: 1)
            if lines.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(lines == [LogLine(lineNumber: 1, text: "one")])

        // The command record must still show `running` at this point — the
        // line landed well before the child exits.
        let record = await state.listCommands().first
        #expect(record?.status == .running)

        runTask.cancel()
        _ = try? await runTask.value
    }

    @Test func killProcessMidStreamCapturesLinesEmittedBeforeTheKill() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runTask = Task {
            try await runner.run(.init(command: "echo captured; sleep 30"))
        }
        defer {
            runTask.cancel()
        }

        // Wait for the emitted line to land before killing, so the kill
        // genuinely races against already-flushed output, not empty output.
        var lines: [LogLine] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while lines.isEmpty, clock.now < deadline {
            lines = try await state.getLines(commandID: 1)
            if lines.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(!lines.isEmpty)

        let record = try await state.killProcess(commandID: 1)
        #expect(record.status == .killed)
        #expect(record.lineCount > 0)

        runTask.cancel()
        _ = try? await runTask.value
    }

    // MARK: - Timeout wall-clock and the no-timeout default

    @Test func requestedTimeoutKillsWellBeforeTheCommandWouldFinish() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try await runner.run(.init(command: "sleep 30", timeout: .milliseconds(400)))
        let elapsed = clock.now - start

        #expect(outcome.status == .timedOut)
        #expect(outcome.exitCode == -1)
        #expect(elapsed < .seconds(3), "timeout took \(elapsed), expected well under the 30s sleep")
    }

    @Test func noTimeoutIsAppliedWhenNoneRequested() async throws {
        let (runner, _, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // With no timeout the command runs to natural completion (a default
        // timeout would have to be < 1s to kill it, and there is none).
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try await runner.run(.init(command: "sleep 1"))
        let elapsed = clock.now - start

        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 0)
        #expect(elapsed >= .milliseconds(900), "sleep 1 finished suspiciously early (\(elapsed))")
    }

    // MARK: - ProcessRegistry: register/deregister lifecycle across a run

    /// `run(_:)` registers the child's pid right after `state.registerProcess`
    /// (visible in the registry while the command is still executing) and
    /// deregisters it on the `defer` teardown site — so a completed run leaves
    /// a private registry empty again.
    @Test func runRegistersTheChildDuringExecutionAndDeregistersAfterCompletion() async throws {
        let registry = ProcessRegistry()
        let (runner, _, tmp) = try makeRunner(registry: registry)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runTask = Task {
            try await runner.run(.init(command: "echo one; sleep 0.3"))
        }
        defer { runTask.cancel() }

        // Poll until the still-running child shows up in the registry.
        let clock = ContinuousClock()
        let registeredDeadline = clock.now.advanced(by: .seconds(2))
        while registry.registeredPids.isEmpty, clock.now < registeredDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!registry.registeredPids.isEmpty, "expected the child's pid to be registered while running")

        _ = try await runTask.value

        #expect(registry.registeredPids.isEmpty, "expected the registry to be empty once the run completed")
    }

    // MARK: - Detached execution: soft-deadline wait + background supervision

    /// `run(_:wait:)` on a slow command returns `.running(commandID)` once
    /// `wait` elapses, well before the child itself finishes — the soft
    /// deadline bounds the *call*, not the child.
    @Test func runWithWaitDeadlineReturnsRunningPromptlyForASlowCommand() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(.init(command: "sleep 30"), wait: .seconds(1))
        let elapsed = clock.now - start

        guard case .running(let commandID) = result else {
            Issue.record("expected .running, got \(result)")
            return
        }
        #expect(commandID == 1)
        #expect(elapsed >= .milliseconds(900), "returned suspiciously early (\(elapsed))")
        #expect(elapsed < .seconds(3), "took too long to detach (\(elapsed))")

        let record = await state.listCommands().first { $0.id == commandID }
        #expect(record?.status == .running)

        // Clean up: kill the still-running detached child so it doesn't
        // outlive the test.
        _ = try? await state.killProcess(commandID: commandID)
    }

    /// A command detached past its `wait` deadline keeps draining and
    /// recording output, and finalizes `state` itself once it exits — the
    /// background half of the split `run(_:)`.
    @Test func detachedCommandFinalizesInBackgroundOnceItExits() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await runner.run(
            .init(command: "echo detached; sleep 0.3"), wait: .milliseconds(50))
        guard case .running(let commandID) = result else {
            Issue.record("expected .running, got \(result)")
            return
        }

        let record = await waitForRecord(
            in: state, commandID: commandID, deadline: .seconds(3), until: { $0.status != .running })
        #expect(record?.status == .completed)
        #expect(record?.exitCode == 0)

        let lines = try await state.getLines(commandID: commandID)
        #expect(lines == [LogLine(lineNumber: 1, text: "detached")])
    }

    /// `timeout` still bounds the child on the detached path — it ticks
    /// inside the body task group regardless of whether anyone is still
    /// awaiting it — killing the group and finalizing the record
    /// `timed_out` once it fires.
    @Test func detachedTimeoutFiresAndKillsTheGroup() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = Int.random(in: 100_000...999_999)
        let command = "sleep \(marker)"
        let pattern = "sleep \(marker)"

        let result = try await runner.run(
            .init(command: command, timeout: .milliseconds(400)), wait: .milliseconds(50))
        guard case .running(let commandID) = result else {
            Issue.record("expected .running, got \(result)")
            return
        }

        let record = await waitForRecord(
            in: state, commandID: commandID, deadline: .seconds(3), until: { $0.status != .running })
        #expect(record?.status == .timedOut)
        #expect(record?.exitCode == -1)

        let survivors = await waitForProcessCount(
            matching: pattern, deadline: .seconds(2), until: { $0 == 0 })
        #expect(survivors == 0, "the timed-out group left \(survivors) survivor(s)")
    }

    /// Cancelling the *awaiting* task mid-wait must detach the child rather
    /// than kill it: the record stays `running`, the child stays alive, and
    /// it is still supervised (finalizes normally later, or via an explicit
    /// kill) — the new cancellation contract for the finite-`wait` path.
    @Test func cancellingTheAwaitingTaskDuringTheWaitDetachesTheChildWithoutKillingIt() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = Int.random(in: 100_000...999_999)
        let command = "sleep \(marker)"
        let pattern = "sleep \(marker)"

        let runTask = Task {
            try await runner.run(.init(command: command), wait: .seconds(10))
        }
        defer {
            Task { _ = try? await state.killProcess(commandID: 1) }
        }

        // Let the child actually spawn before cancelling.
        let alive = await waitForProcessCount(matching: pattern, deadline: .seconds(2), until: { $0 >= 1 })
        #expect(alive >= 1, "expected the child to be running before cancelling")

        runTask.cancel()
        let result = try await runTask.value

        guard case .running(let commandID) = result else {
            Issue.record("expected cancellation to detach with .running, got \(result)")
            return
        }

        // The child is still alive — cancellation must not have killed it.
        let stillAlive = processCount(matching: pattern)
        #expect(stillAlive >= 1, "cancellation must not kill the detached child")

        let record = await state.listCommands().first { $0.id == commandID }
        #expect(record?.status == .running)

        // It is still supervised: an explicit kill still reaches it.
        let killed = try await state.killProcess(commandID: commandID)
        #expect(killed.status == .killed)
        let survivors = await waitForProcessCount(
            matching: pattern, deadline: .seconds(2), until: { $0 == 0 })
        #expect(survivors == 0)
    }
}
