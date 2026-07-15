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
            commandId: 7,
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
            commandId: 1,
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
}
