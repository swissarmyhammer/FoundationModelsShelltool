import FoundationModels
import Foundation
import Operations
import Testing

@testable import ShellTool

/// Exercises the `execute command` operation through the model-facing dispatch
/// path — `OperationTool.call` → `AnyOperation` → `ExecuteCommand.execute(in:)`
/// against a real `ShellContext` that spawns real subprocesses.
@Suite struct ExecuteCommandTests {

    /// Build a fresh tool over a `ShellContext` rooted at a unique temp `.shell`
    /// store, with a builtin-only policy (no `~/.shell` or project overlay), so
    /// every test is isolated and deterministic.
    private func makeTool() throws -> OperationTool<ShellContext> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        let context = ShellContext(state: state, policy: policy)
        return try OperationTool(
            name: "shell",
            description: "Run shell commands.",
            context: context,
            operations: [AnyOperation(ExecuteCommand.self)]
        )
    }

    @Test func executeCommandDispatchesThroughAnyOperationAndRunsARealCommand() async throws {
        let tool = try makeTool()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "echo hello",
            ])
        )

        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("\"exitCode\":0"))
        #expect(json.contains("1: hello"))
    }

    @Test func missingRequiredCommandParamReturnsACorrectiveMessage() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command"])
        )

        #expect(response.contains("Missing required"))
        #expect(response.contains("command"))
    }

    @Test func deniedCommandReturnsACorrectiveMessageRatherThanThrowing() async throws {
        let tool = try makeTool()

        // `sudo\s+` is a builtin deny pattern (privilege escalation).
        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sudo apt-get update",
            ])
        )

        #expect(response.contains("Command blocked by shell policy"))
        #expect(response.contains("Privilege escalation"))
    }

    @Test func emptyCommandReturnsACorrectiveMessageRatherThanRunning() async throws {
        let tool = try makeTool()

        // The key is present (so it is not a "missing required" failure) but the
        // value is blank — Rust's `validate_not_empty` rejects this first.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "   ",
            ])
        )

        #expect(response.contains("Shell command cannot be empty"))
        // A corrective message, not a run: no structured result fields.
        #expect(!response.contains("\"status\""))
        #expect(!response.contains("\"commandId\""))
    }

    @Test func outputNoteBoundaryIsStrictlyGreaterThanThirtyTwo() async throws {
        let tool = try makeTool()

        // Exactly 32: the full output, no tail note, all 32 lines echoed.
        let atBoundary = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "seq 1 32",
            ])
        )
        #expect(atBoundary.contains("\"lines\":32"))
        #expect(!atBoundary.contains("outputNote"))
        // Quoted JSON-array elements, so `"1: 1"` cannot match inside `"11: 11"`.
        #expect(atBoundary.contains("\"1: 1\""))
        #expect(atBoundary.contains("\"32: 32\""))

        // 33: one past the boundary, the tail note appears naming "last 32 of 33".
        let pastBoundary = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "seq 1 33",
            ])
        )
        #expect(pastBoundary.contains("\"lines\":33"))
        #expect(pastBoundary.contains("\"outputNote\":"))
        #expect(pastBoundary.contains("last 32 of 33"))
        #expect(pastBoundary.contains("\"33: 33\""))
        // Line 1 is outside the trailing 32-line window (2…33), so its element
        // is absent (checked quoted to avoid matching inside `"11: 11"`).
        #expect(!pastBoundary.contains("\"1: 1\""))
    }

    @Test func outputNoteAppearsOnlyWhenTotalLinesExceedThirtyTwo() async throws {
        let tool = try makeTool()

        // 40 lines > 32: the tail note is present and names "last 32 of 40",
        // and only the trailing window (lines 9…40) is echoed back.
        let truncated = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "seq 1 40",
            ])
        )
        #expect(truncated.contains("\"lines\":40"))
        #expect(truncated.contains("\"outputNote\":"))
        #expect(truncated.contains("last 32 of 40"))
        #expect(truncated.contains("40: 40"))
        #expect(truncated.contains("9: 9"))
        #expect(!truncated.contains("8: 8"))

        // 5 lines <= 32: no tail note at all.
        let full = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "seq 1 5",
            ])
        )
        #expect(full.contains("\"lines\":5"))
        #expect(!full.contains("outputNote"))
    }

    @Test func executeResultEncodesTheExpectedFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let withNote = ExecuteResult(
            commandID: 7,
            status: "completed",
            exitCode: 0,
            lines: 40,
            durationMs: 12,
            output: ["40: forty"],
            outputNote: "showing last 32 of 40 lines"
        )
        let json = try #require(String(data: try encoder.encode(withNote), encoding: .utf8))

        #expect(json.contains("\"commandId\":7"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("\"exitCode\":0"))
        #expect(json.contains("\"lines\":40"))
        #expect(json.contains("\"durationMs\":12"))
        #expect(json.contains("\"output\":[\"40: forty\"]"))
        #expect(json.contains("\"outputNote\":\"showing last 32 of 40 lines\""))

        // A nil `outputNote` is omitted entirely (synthesized `encodeIfPresent`).
        let withoutNote = ExecuteResult(
            commandID: 1,
            status: "completed",
            exitCode: 0,
            lines: 1,
            durationMs: 3,
            output: ["1: hi"],
            outputNote: nil
        )
        let bare = try #require(String(data: try encoder.encode(withoutNote), encoding: .utf8))
        #expect(!bare.contains("outputNote"))
    }

    @Test func snakeCaseAndCamelCaseWorkingDirectoryResolveIdentically() async throws {
        // A temp working directory holding a uniquely-named marker file: a run
        // whose `working_directory`/`workingDirectory` key resolved will list
        // the marker; one whose key was dropped runs elsewhere and won't.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-wd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = "parity-marker-file"
        try "x".write(
            to: directory.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snakeTool = try makeTool()
        let snake = try await snakeTool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "ls", "working_directory": directory.path,
            ])
        )

        let camelTool = try makeTool()
        let camel = try await camelTool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "ls", "workingDirectory": directory.path,
            ])
        )

        #expect(snake.contains(marker))
        #expect(camel.contains(marker))
    }

    // MARK: - waitSeconds: default constant

    @Test func defaultWaitSecondsConstantIsThirty() {
        #expect(ExecuteCommand.defaultWaitSeconds == 30)
    }

    // MARK: - waitSeconds: soft-deadline duration is a pure computation

    /// `waitDuration(for:)` is the pure computation `execute(in:)` uses to
    /// turn `waitSeconds` into the `Duration` passed to
    /// `ShellRunner.run(_:wait:)`. Testing it directly — rather than only
    /// observing a real 30-second detach — pins the omitted-`waitSeconds`
    /// default via the named constant without ever waiting 30 seconds.
    @Test func waitDurationOmittedUsesTheDefaultWaitSecondsConstant() {
        #expect(ExecuteCommand.waitDuration(for: nil) == .seconds(ExecuteCommand.defaultWaitSeconds))
        #expect(ExecuteCommand.waitDuration(for: nil) == .seconds(30))
    }

    @Test func waitDurationZeroDetachesImmediately() {
        #expect(ExecuteCommand.waitDuration(for: 0) == .seconds(0))
    }

    @Test func waitDurationPositiveUsesTheGivenSeconds() {
        #expect(ExecuteCommand.waitDuration(for: 5) == .seconds(5))
    }

    // MARK: - waitSeconds: fast command JSON byte-shape is unchanged

    /// The fast-path regression this task must not break: an omitted
    /// `waitSeconds` still resolves through the default deadline well before
    /// it elapses, and the finished-command JSON shape is unchanged —
    /// `status: "completed"`, `exitCode` present.
    @Test func fastCommandJSONShapeIsUnchangedWithWaitSecondsOmitted() async throws {
        let tool = try makeTool()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo hi"]))

        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("\"exitCode\":0"))
        #expect(!json.contains("\"status\":\"running\""))
    }

    // MARK: - waitSeconds: negative value is corrective

    /// Drives `ExecuteCommand.execute(in:)` directly, mirroring
    /// `GetLines`'s equivalent test: a negative `waitSeconds` must come back
    /// as the pinned corrective `ExecuteOutput`, not a thrown error and not a
    /// `.ran` result — and, crucially, without ever spawning a child.
    @Test func executeCommandExecuteReturnsCorrectiveOutputForNegativeWaitSeconds() async throws {
        let context = try makeContext()
        let operation = try ExecuteCommand(
            GeneratedContent(properties: ["command": "echo hi", "waitSeconds": -1]))

        let output = try await operation.execute(in: context)

        guard case .corrective(let message) = output else {
            Issue.record("expected a .corrective ExecuteOutput, got \(output)")
            return
        }
        #expect(message == "waitSeconds must be non-negative")

        // Nothing ran: the history stays empty.
        #expect(await context.state.listCommands().isEmpty)
    }

    @Test func negativeWaitSecondsReturnsTheCorrectiveMessageThroughTheFusedTool() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "echo hi", "waitSeconds": -1,
            ]))

        #expect(response.contains("waitSeconds must be non-negative"))
        // A corrective message, not a structured result.
        #expect(!response.contains("\"commandId\""))
    }

    // MARK: - waitSeconds: soft-deadline detach for a slow command

    /// Build a fused tool plus its backing `ShellContext`, for tests that
    /// need direct access to `ShellState` — e.g. to kill a detached child
    /// left running once the wait deadline elapses.
    private func makeToolWithContext() throws -> (OperationTool<ShellContext>, ShellContext) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        let context = ShellContext(state: state, policy: policy)
        let tool = try OperationTool(
            name: "shell",
            description: "Run shell commands.",
            context: context,
            operations: [AnyOperation(ExecuteCommand.self)]
        )
        return (tool, context)
    }

    /// The load-bearing acceptance test: `sleep 30` with `waitSeconds: 1`
    /// returns in ~1s carrying `status: "running"`, a valid `commandId`, no
    /// `exitCode` key at all, and an `outputNote` naming the follow-up
    /// protocol (`get lines`, `kill process`).
    @Test func slowCommandWithOneSecondWaitReturnsARunningResultPromptly() async throws {
        let (tool, context) = try makeToolWithContext()
        defer { Task { _ = try? await context.state.killProcess(commandID: 1) } }

        let clock = ContinuousClock()
        let start = clock.now
        let json = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sleep 30", "waitSeconds": 1,
            ]))
        let elapsed = clock.now - start

        #expect(elapsed >= .milliseconds(900), "returned suspiciously early (\(elapsed))")
        #expect(elapsed < .seconds(5), "took too long to detach (\(elapsed))")
        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"status\":\"running\""))
        #expect(!json.contains("\"exitCode\""))
        #expect(json.contains("get lines"))
        #expect(json.contains("kill process"))
    }

    /// `waitSeconds: 0` detaches immediately rather than waiting any
    /// fraction of a second — the "0 returns immediately" contract.
    @Test func waitSecondsZeroDetachesImmediatelyForASlowCommand() async throws {
        let (tool, context) = try makeToolWithContext()
        defer { Task { _ = try? await context.state.killProcess(commandID: 1) } }

        let clock = ContinuousClock()
        let start = clock.now
        let json = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sleep 30", "waitSeconds": 0,
            ]))
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(2), "waitSeconds: 0 should detach almost immediately (\(elapsed))")
        #expect(json.contains("\"status\":\"running\""))
        #expect(!json.contains("\"exitCode\""))
    }

    // MARK: - waitSeconds: timeout still bounds a detached command

    /// `timeout` bounds the *child*; `waitSeconds` only bounds this call.
    /// Detaching via `waitSeconds: 0` must not disarm `timeout` — the
    /// background supervision still kills the group and records
    /// `timed_out` once it fires.
    @Test func timeoutStillFiresOnACommandDetachedByWaitSeconds() async throws {
        let context = try makeContext()
        let marker = Int.random(in: 100_000...999_999)
        let operation = try ExecuteCommand(
            GeneratedContent(properties: [
                "command": "sleep \(marker)", "timeout": 1, "waitSeconds": 0,
            ]))

        let output = try await operation.execute(in: context)
        guard case .ran(let result) = output else {
            Issue.record("expected a .ran ExecuteOutput, got \(output)")
            return
        }
        #expect(result.status == "running")
        #expect(result.exitCode == nil)

        let record = await waitForRecord(
            in: context.state, commandID: result.commandID, deadline: .seconds(3),
            until: { $0.status != .running })
        #expect(record?.status == .timedOut)
        #expect(record?.exitCode == -1)
    }

    /// Poll `state.listCommands()` for `commandID`'s record until it
    /// satisfies `predicate` or `deadline` passes; returns the last observed
    /// record (`nil` if the id was never started). Mirrors
    /// `ShellRunnerTests.waitForRecord`.
    private func waitForRecord(
        in state: ShellState, commandID: Int, deadline: Duration,
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

    /// Build a fresh `ShellContext` rooted at a unique temp `.shell` store,
    /// with a builtin-only policy (no `~/.shell` or project overlay), for
    /// tests that drive `ExecuteCommand.execute(in:)` directly rather than
    /// through a fused tool.
    private func makeContext() throws -> ShellContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        return ShellContext(state: state, policy: policy)
    }

    // MARK: - waitSeconds: ExecuteResult encoding (exitCode omitted while running)

    @Test func executeResultOmitsExitCodeWhenNil() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let running = ExecuteResult(
            commandID: 1,
            status: "running",
            exitCode: nil,
            lines: 0,
            durationMs: 500,
            output: [],
            outputNote: "still running"
        )
        let json = try #require(String(data: try encoder.encode(running), encoding: .utf8))

        #expect(json.contains("\"status\":\"running\""))
        #expect(json.contains("\"durationMs\":500"))
        #expect(!json.contains("exitCode"))
    }
}
