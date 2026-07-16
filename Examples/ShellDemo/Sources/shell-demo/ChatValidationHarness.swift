// `ChatValidationHarness` — the `shell-demo --chat` live-model validation.
//
// The full-stack analogue of the upstream `notes --chat` harness, adapted to
// the shell tool's scenarios. It registers the fused `shell` tool on a
// `LanguageModelSession` and drives a scripted prompt set that exercises the
// tool's three signature behaviors:
//
//   - long output → tail note → follow-up: run a command whose output exceeds
//     the 32-line tail, so the model sees the "showing last 32 of N lines" note
//     and follows up with `grep history` / `get lines` to read the rest;
//   - background process lifecycle: start a `sleep`-style long command, `list
//     processes` to find it, then `kill process` it;
//   - denied command recovery: ask for `sudo rm -rf /`, which `ShellPolicy`
//     rejects with a corrective message, and confirm the model rephrases within
//     the retry cap rather than looping forever.
//
// It reports op-call accuracy over the scripted set, the fused tool's rendered
// schema size via `tokenCount(for:)`, and the retry-cap behavior on the denied
// command.
//
// MANUAL-RUN ONLY — never part of `swift test`. It needs an Apple
// Intelligence-enabled device, which CI does not have (plan §7.4): `run()`
// degrades to a skip message off-device instead of failing, so invoking it in
// CI is harmless. The automated suite documents this exclusion explicitly in
// `ExampleIntegrationTests.chatModeIsExcludedFromTheAutomatedSuite`.

import FoundationModels
import Operations
import ShellTool

/// Drives the scripted live-model validation `shell-demo --chat` runs.
enum ChatValidationHarness {
    /// One scripted prompt and the op the shell tool should be dispatched to in
    /// response.
    private struct ScriptedPrompt: Sendable {
        /// The natural-language prompt sent to the model.
        let prompt: String
        /// The `"verb noun"` op string the model is expected to dispatch.
        let expectedOpString: String
    }

    /// The scripted prompt set, in the order a human would run them: a long
    /// command and its truncation follow-ups, then a background process's
    /// lifecycle. Each targets one shell operation.
    private static let scriptedPrompts: [ScriptedPrompt] = [
        ScriptedPrompt(
            prompt: "Run the command `seq 1 100` and show me its output.",
            expectedOpString: "execute command"),
        ScriptedPrompt(
            prompt: "That output was truncated to the last 32 lines. Search the command history for the line that is exactly '50'.",
            expectedOpString: "grep history"),
        ScriptedPrompt(
            prompt: "Now show me lines 1 through 5 of that command's output.",
            expectedOpString: "get lines"),
        ScriptedPrompt(
            prompt: "Start a long-running command in the background: run `sleep 60`.",
            expectedOpString: "execute command"),
        ScriptedPrompt(
            prompt: "List all the commands you've run so far with their status.",
            expectedOpString: "list processes"),
        ScriptedPrompt(
            prompt: "Kill the sleep command — it has command id 2.",
            expectedOpString: "kill process"),
    ]

    /// A command `ShellPolicy` denies, for observing the corrective message and
    /// the retry-cap behavior when the model tries to recover from it.
    private static let deniedCommandPrompt =
        "Delete every file on this machine by running `sudo rm -rf /`."

    /// The instructions the harness's `LanguageModelSession` runs under.
    private static let sessionInstructions =
        "You operate a virtual shell using the shell tool. Always use the tool to run commands, inspect their output, and manage processes."

    /// Runs the live-model validation if `SystemLanguageModel` is available on
    /// this device, otherwise prints a skip message explaining why — never a
    /// hard failure, so a CI run of `--chat` exits cleanly.
    static func run() async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runValidation()
        case .unavailable(let reason):
            let reasonText: String
            switch reason {
            case .deviceNotEligible: reasonText = "device not eligible"
            case .appleIntelligenceNotEnabled: reasonText = "Apple Intelligence not enabled"
            case .modelNotReady: reasonText = "model not ready"
            @unknown default: reasonText = "unknown reason"
            }
            print("Foundation Models unavailable on this device (\(reasonText)); skipping live validation.")
        @unknown default:
            print("Foundation Models availability is unknown on this device; skipping live validation.")
        }
    }

    /// Runs every stage of the validation report in turn.
    private static func runValidation() async {
        do {
            try await reportTokenCount()

            let tool = try ShellTool.make()
            let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
            let accuracy = await measureOpCallAccuracy(session: session, toolName: tool.name)
            print("Op-call accuracy: \(accuracy.matched)/\(accuracy.total) scripted prompts dispatched the expected op.")

            await probeRetryCapBehavior(session: session)
        } catch {
            print("Live validation failed: \(error)")
        }
    }

    /// Prints the fused tool's rendered schema size in tokens, so the plan's
    /// "schema-in-prompt cost" is observable.
    ///
    /// - Throws: Rethrows from `ShellTool.make()` or
    ///   `SystemLanguageModel.tokenCount(for:)`.
    private static func reportTokenCount() async throws {
        guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else {
            print("Token-count reporting requires macOS/iOS/visionOS 26.4 or newer; skipping.")
            return
        }
        let count = try await SystemLanguageModel.default.tokenCount(for: [try ShellTool.make()])
        print("Fused shell tool schema token count: \(count)")
    }

    /// Sends every `scriptedPrompts` entry to `session` and tallies how many
    /// dispatched their expected op.
    ///
    /// - Parameters:
    ///   - session: The session to send scripted prompts to.
    ///   - toolName: The fused tool's name, to find its calls in the session's
    ///     transcript after each response.
    /// - Returns: The number of prompts that matched, out of the total.
    private static func measureOpCallAccuracy(
        session: LanguageModelSession,
        toolName: String
    ) async -> (matched: Int, total: Int) {
        var matched = 0
        for scripted in scriptedPrompts
        where await evaluateScriptedPrompt(scripted, session: session, toolName: toolName) {
            matched += 1
        }
        return (matched, scriptedPrompts.count)
    }

    /// Sends one scripted prompt to `session`, prints whether the resulting tool
    /// call matched its expected op, and reports the outcome.
    ///
    /// - Parameters:
    ///   - scripted: The prompt and its expected op string.
    ///   - session: The session to send the prompt to.
    ///   - toolName: The fused tool's name, to find its call in the transcript.
    /// - Returns: Whether the dispatched op matched `scripted.expectedOpString`.
    private static func evaluateScriptedPrompt(
        _ scripted: ScriptedPrompt,
        session: LanguageModelSession,
        toolName: String
    ) async -> Bool {
        do {
            _ = try await session.respond(to: scripted.prompt)
            let actual = lastToolCallOpString(in: session.transcript, toolName: toolName)
            let matched = actual == scripted.expectedOpString
            let status = matched ? "OK" : "MISS"
            print("[\(status)] \"\(scripted.prompt)\" -> expected '\(scripted.expectedOpString)', got '\(actual ?? "none")'")
            return matched
        } catch {
            print("[ERROR] \"\(scripted.prompt)\" -> \(error)")
            return false
        }
    }

    /// Sends `deniedCommandPrompt` to `session` up to three times in a row,
    /// printing each response so a human can observe the tool's corrective
    /// message (`ShellPolicy` denies `sudo rm -rf /`) give way, within the retry
    /// cap, to the model rephrasing or giving up rather than looping forever
    /// (plan's "retry cap").
    ///
    /// - Parameter session: The session to send the probe requests to.
    private static func probeRetryCapBehavior(session: LanguageModelSession) async {
        print("Retry-cap probe: sending a policy-denied command up to 3 times to observe corrective recovery.")
        for attempt in 1...3 {
            do {
                let response = try await session.respond(to: deniedCommandPrompt)
                let op = lastToolCallOpString(in: session.transcript, toolName: ShellTool.name)
                print("[attempt \(attempt)] dispatched op '\(op ?? "none")'; model responded: \(response.content)")
            } catch {
                print("[attempt \(attempt)] session threw: \(error)")
            }
        }
    }

    /// The `op` argument of the most recent call to the tool named `toolName` in
    /// `transcript`, or `nil` if it contains none.
    ///
    /// - Parameters:
    ///   - transcript: The session transcript to search.
    ///   - toolName: The tool name to match `Transcript.ToolCall.toolName`
    ///     against.
    private static func lastToolCallOpString(in transcript: Transcript, toolName: String) -> String? {
        var lastMatch: String?
        for entry in transcript {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls where call.toolName == toolName {
                lastMatch = try? call.arguments.value(String.self, forProperty: OperationKeys.opFieldName)
            }
        }
        return lastMatch
    }
}
