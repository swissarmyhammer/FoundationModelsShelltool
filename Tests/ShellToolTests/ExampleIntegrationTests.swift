// `ExampleIntegrationTests` — end-to-end coverage of the `shell-demo` example.
//
// Two layers, matching the example's two automatable modes:
//
//   1. The model/CLI dispatch path: every one of the five fused operations is
//      driven through `OperationTool.call` (the `AnyOperation` dispatch a model
//      call takes) over a tool built the way the executable builds it —
//      `ShellTool.make(preferredDirectory:)`, the contextless factory the
//      `shell-demo` composition root uses. This pins that the example's own
//      construction path round-trips every op end-to-end.
//
//   2. The `--script` mode: the built `shell-demo` executable is launched as a
//      subprocess with `--script`, and a fixed sequence of op lines is piped
//      through its real standard input. This exercises the one-process /
//      shared-session contract (plan §3): because every line runs against the
//      one tool/context the single process built, an `execute` earlier in the
//      stream is visible to a `grep history` / `get lines` later in the same
//      stream — the whole point of the mode.
//
// The `--chat` mode is DELIBERATELY excluded from this automated suite — it
// needs a live, Apple-Intelligence-enabled on-device model, which CI does not
// have, so it is a manual-run harness (`shell-demo --chat`) instead. See the
// "--chat exclusion" section at the end of this file for the documented
// rationale; it is recorded here rather than silently omitted.

import FoundationModels
import Foundation
import Operations
import Testing

@testable import ShellTool

@Suite struct ExampleIntegrationTests {

    // MARK: - --script subprocess harness

    /// The built `shell-demo` executable, located next to the running test
    /// bundle (SwiftPM places both under `.build/<config>/`). Declared as a
    /// dependency of the test target, so `swift test` builds it first.
    ///
    /// Tries the `.xctest` bundle's directory first (the products directory),
    /// then falls back to `<cwd>/.build/debug/shell-demo` — the stable symlink
    /// SwiftPM maintains — since `swift test` runs with the package root as its
    /// working directory.
    private static func shellDemoBinary() throws -> URL {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("shell-demo"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".build/debug/shell-demo"))
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ScriptError.binaryNotFound(candidates)
        }
        return binary
    }

    /// Failures raised by the subprocess harness itself (not by the tool).
    private enum ScriptError: Error {
        /// The `shell-demo` binary could not be found among the candidates.
        case binaryNotFound([URL])
    }

    /// The result of running `shell-demo --script`: its combined output and
    /// process exit code.
    private struct ScriptRun {
        /// Standard output and standard error, combined in emission order.
        let output: String
        /// The subprocess's exit status.
        let exitCode: Int32
    }

    /// Launch `shell-demo --script` in a fresh temp working directory, pipe
    /// `input` (the newline-separated op lines) through its standard input, and
    /// collect its output and exit code.
    ///
    /// The working directory is a unique temp dir, so the executable's default
    /// `<cwd>/.shell` store lands there — not in the repo — and is removed after
    /// the run. Output is read to EOF *before* `waitUntilExit()` so a large
    /// stream can never deadlock against a full pipe buffer.
    ///
    /// - Parameter input: The op lines to feed on standard input.
    /// - Returns: The subprocess's combined output and exit code.
    private static func runScript(input: String) throws -> ScriptRun {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-script-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = try shellDemoBinary()
        process.arguments = ["--script"]
        process.currentDirectoryURL = workingDirectory

        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        try inputPipe.fileHandleForWriting.close()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptRun(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }

    // MARK: - --script: one-process shared-session contract

    @Test func scriptModeSharesOneSessionAcrossExecuteThenGetLines() throws {
        // Two op lines in one process: run a command, then read its stored
        // output back by the id the first line assigned. The `get lines` can
        // only see those lines if it ran against the *same* session/context —
        // the one-process-shared-session contract (plan §3).
        let run = try Self.runScript(input: """
            command execute --command "printf 'alpha\\nbeta\\n'"
            lines get --command-id 1
            """)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("1: alpha"))
        #expect(run.output.contains("2: beta"))
    }

    // MARK: - CLI integration: a full flow through the built executable

    @Test func scriptModeDrivesAFullExecuteGrepGetLinesFlowInOneProcess() throws {
        // The full read-back flow the plan calls out — execute, then grep the
        // recorded output, then fetch specific lines — all in one subprocess,
        // sharing one session. Each downstream op depending on the first is the
        // proof the built executable wires a single shared context across lines.
        let run = try Self.runScript(input: """
            command execute --command "printf 'needle\\nhaystack\\n'"
            history grep --pattern needle
            lines get --command-id 1 --start 2 --end 2
            """)

        #expect(run.exitCode == 0)
        // execute echoed the tail of its own output.
        #expect(run.output.contains("1: needle"))
        // grep found the needle in the recorded history and reported the count.
        #expect(run.output.contains("\"total\":1"))
        // get lines fetched exactly the bounded second line.
        #expect(run.output.contains("2: haystack"))
    }

    @Test func scriptModeSkipsBlankAndCommentLines() throws {
        // Blank lines and `#` comments are ignored, so a human can annotate a
        // script without those lines being parsed as (failing) op invocations.
        let run = try Self.runScript(input: """
            # run a command
            command execute --command "echo hi"

            lines get --command-id 1
            """)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("1: hi"))
    }

    // MARK: - every op through the AnyOperation dispatch path

    /// Build a fused tool over a temp-dir store the way the `shell-demo`
    /// executable does — the contextless `ShellTool.make(preferredDirectory:)`
    /// factory — so the drive-through tests take the example's own construction
    /// path, not a `@testable` context shortcut. A unique temp dir keeps each
    /// test isolated.
    private func makeExampleTool() throws -> OperationTool<ShellContext> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-example-\(UUID().uuidString)", isDirectory: true)
        return try ShellTool.make(preferredDirectory: directory)
    }

    @Test func executeCommandRoundTripsThroughAnyOperation() async throws {
        let tool = try makeExampleTool()
        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo hi"]))
        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("1: hi"))
    }

    @Test func listProcessesRoundTripsThroughAnyOperation() async throws {
        let tool = try makeExampleTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo seed"]))
        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(json.contains("\"command\":\"echo seed\""))
        #expect(json.contains("\"status\":\"completed\""))
    }

    @Test func grepHistoryRoundTripsThroughAnyOperation() async throws {
        let tool = try makeExampleTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "printf 'MARK\\nMARK\\n'"]))
        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "grep history", "pattern": "MARK"]))
        #expect(json.contains("\"total\":2"))
    }

    @Test func getLinesRoundTripsThroughAnyOperation() async throws {
        let tool = try makeExampleTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "printf 'alpha\\nbeta\\n'"]))
        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines", "command_id": 1]))
        #expect(json.contains("1: alpha"))
        #expect(json.contains("2: beta"))
    }

    @Test func killProcessRoundTripsThroughAnyOperation() async throws {
        let tool = try makeExampleTool()
        // No running process for an unknown id: the op returns its corrective
        // message rather than throwing, so the dispatch path completes normally.
        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process", "id": 999]))
        #expect(json.contains("No running process"))
    }

    // MARK: - --chat exclusion (documented, not silently omitted)
    //
    // `--chat` mode is intentionally NOT covered by an automated test, and this
    // is a deliberate exclusion recorded here rather than a silent omission.
    //
    // The mode drives a live `LanguageModelSession` over the on-device
    // Foundation model, which requires an Apple-Intelligence-enabled device that
    // CI does not provide (`ChatValidationHarness` degrades to a skip message
    // off device). Its scripted validation — op-call accuracy, the fused tool's
    // `tokenCount(for:)` schema size, and the retry-cap behavior on the denied
    // `sudo rm -rf /` scenario — is a MANUAL-RUN harness invoked as
    // `swift run shell-demo --chat`, not a `swift test` case (plan §7.4).
    //
    // A tautological `@Test` marker is deliberately avoided (the suite dropped
    // one previously): the exclusion lives in prose here and in the file header,
    // so it is discoverable without a test that asserts nothing. What the suite
    // *does* cover is everything `--chat` shares with the other modes — the five
    // ops' dispatch (the AnyOperation round-trips above) and the fused tool
    // construction (`ShellTool.make`) the harness itself builds on.
}
