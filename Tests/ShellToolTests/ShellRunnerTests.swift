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
    private func makeRunner() throws -> (ShellRunner, ShellState, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellrunner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let state = try ShellState(preferredDirectory: tmp.appendingPathComponent(".shell"))
        return (ShellRunner(state: state), state, tmp)
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

        let lines = try await state.getLines(commandId: outcome.commandId)
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
        let lines = try await state.getLines(commandId: outcome.commandId)
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
        let lines = try await state.getLines(commandId: outcome.commandId)
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
        let runner = ShellRunner(state: state, maxOutputSize: 200)

        let outcome = try await runner.run(
            .init(command: "for i in $(seq 1 60); do echo \"line$i\"; done"))
        #expect(outcome.status == .completed)
        #expect(outcome.exitCode == 0)

        let lines = try await state.getLines(commandId: outcome.commandId)
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
        let lines = try await state.getLines(commandId: outcome.commandId)
        #expect(lines == [LogLine(lineNumber: 1, text: "[Binary content: 7 bytes]")])
    }

    // MARK: - Interleaving: stdout lines precede stderr, one shared counter

    @Test func stdoutLinesPrecedeStderrLinesInTheLog() async throws {
        let (runner, state, tmp) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outcome = try await runner.run(
            .init(command: "echo out1; echo err1 >&2; echo out2; echo err2 >&2"))
        let lines = try await state.getLines(commandId: outcome.commandId)
        #expect(lines == [
            LogLine(lineNumber: 1, text: "out1"),
            LogLine(lineNumber: 2, text: "out2"),
            LogLine(lineNumber: 3, text: "err1"),
            LogLine(lineNumber: 4, text: "err2"),
        ])
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
}
