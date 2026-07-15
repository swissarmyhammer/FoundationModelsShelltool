import FoundationModels
import Foundation
import Operations
import Testing

@testable import ShellTool

/// Exercises the *fusion* wiring `ShellTool.make(context:)` assembles — the five
/// operations behind one `OperationTool<ShellContext>` named `"shell"` — rather
/// than each operation's logic, which the per-op suites (`ExecuteCommandTests`,
/// `ProcessOpsTests`, `HistoryOpsTests`) already cover in isolation.
///
/// The point of interest here is that all five ops dispatch correctly *through
/// the single fused tool* by their exact sah op strings, that an op-less payload
/// defaults to `execute command` via the resolver's `inferOp` hook, and that the
/// fused schema is the flat union `SchemaFusion` builds: a required `op` enum of
/// exactly the five op strings plus every field optional.
@Suite struct FusionTests {

    /// Build the fused `shell` tool over a `ShellContext` rooted at a unique temp
    /// `.shell` store, with a builtin-only policy (no `~/.shell` or project
    /// overlay), so every test is isolated and deterministic — and, crucially,
    /// through the real `ShellTool.make(context:)` factory rather than a
    /// hand-rolled `OperationTool` init, so these tests exercise the fusion the
    /// library ships.
    private func makeTool() throws -> OperationTool<ShellContext> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        let context = ShellContext(state: state, policy: policy)
        return try ShellTool.make(context: context)
    }

    // MARK: - construction

    @Test func makeReturnsAToolNamedShell() throws {
        let tool = try makeTool()

        #expect(tool.name == "shell")
    }

    @Test func makeCarriesTheSahDescription() throws {
        let tool = try makeTool()

        #expect(
            tool.description
                == "Virtual shell with history and process management. Execute commands, grep output history, and manage running processes."
        )
    }

    // MARK: - per-op dispatch through the fused tool

    @Test func executeCommandDispatchesThroughTheFusedTool() async throws {
        let tool = try makeTool()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "echo hello",
            ]))

        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("1: hello"))
    }

    @Test func listProcessesDispatchesThroughTheFusedTool() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo alpha"]))

        let listed = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))

        #expect(listed.hasPrefix("["))
        #expect(listed.contains("\"id\":1"))
        #expect(listed.contains("echo alpha"))
    }

    @Test func killProcessDispatchesThroughTheFusedTool() async throws {
        let tool = try makeTool()

        // An unknown id reaches `KillProcess` and comes back as its corrective
        // string — proving the fused tool routed `kill process` to that op
        // without spawning (and having to reap) a real long-lived child.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process", "id": 999]))

        #expect(response.contains("No running process"))
        #expect(response.contains("999"))
    }

    @Test func grepHistoryDispatchesThroughTheFusedTool() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'MARK\\nMARK\\n'",
            ]))

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "grep history", "pattern": "MARK"]))

        #expect(response.contains("\"total\":2"))
        #expect(response.contains("\"text\":\"MARK\""))
    }

    @Test func getLinesDispatchesThroughTheFusedTool() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'alpha\\nbeta\\n'",
            ]))

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines", "command_id": 1]))

        #expect(response.contains("\"commandId\":1"))
        #expect(response.contains("1: alpha"))
        #expect(response.contains("2: beta"))
    }

    // MARK: - missing-op default

    @Test func missingOpDefaultsToExecuteCommand() async throws {
        let tool = try makeTool()

        // No `op` field at all: the resolver's `inferOp` hook must propose
        // `execute command`, so this runs the command rather than failing to
        // resolve an operation.
        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["command": "echo defaulted"]))

        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("1: defaulted"))
    }

    // MARK: - fused schema spot-check

    /// Encode the fused tool's rendered `parameters` schema to JSON and decode it
    /// back to a plain object, so the assertions read Apple's rendered schema
    /// structurally rather than snapshotting its byte encoding.
    private func fusedSchemaObject(_ tool: OperationTool<ShellContext>) throws -> [String: Any] {
        let data = try JSONEncoder().encode(tool.parameters)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test func fusedSchemaOpEnumHasExactlyTheFiveOpStrings() throws {
        let tool = try makeTool()
        let object = try fusedSchemaObject(tool)
        let properties = try #require(object["properties"] as? [String: Any])
        let opSchema = try #require(properties["op"] as? [String: Any])
        let opEnum = try #require(opSchema["enum"] as? [String])

        #expect(
            Set(opEnum)
                == Set(["execute command", "list processes", "kill process", "grep history", "get lines"]))
        #expect(opEnum.count == 5)
    }

    @Test func fusedSchemaRequiresOnlyOpEveryOtherFieldOptional() throws {
        let tool = try makeTool()
        let object = try fusedSchemaObject(tool)
        let required = try #require(object["required"] as? [String])

        #expect(required == ["op"])
    }
}
