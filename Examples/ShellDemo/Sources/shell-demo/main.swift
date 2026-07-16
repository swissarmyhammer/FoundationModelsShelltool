// `shell-demo` — example executable exercising the fused `shell` tool in three
// modes, the full-stack analogue of the upstream `notes` executable
// (`NotesToolMain`).
//
// The tool is fused from the five operations with the contextless
// `ShellTool.make()` factory (which assembles a default `ShellContext` rooted at
// `<cwd>/.shell`). The three modes, selected by the first argument, are:
//
//   - default — CLI: drive argv through an `OperationCLIDriver` over the fused
//     tool. The driver assembles the noun-verb grammar — `command execute`,
//     `processes list`, `process kill`, `history grep`, `lines get` — from each
//     operation's `@Operation(verb:noun:)`, with stock ArgumentParser handling
//     help, did-you-mean, and completion scripts.
//   - `--script`: read op lines from standard input and run them sequentially
//     in ONE process against ONE shared session (`ScriptMode`), so an `execute`
//     early in the stream is visible to a later `grep`/`get lines`.
//   - `--chat`: register the tool on a `LanguageModelSession` and run the
//     scripted, availability-gated live-model validation (`ChatValidation
//     Harness`), which degrades to a skip message off-device.
//
// This entry point is deliberately thin composition-root glue (like
// `NotesToolMain`): all dispatch and convergence logic lives in `ShellTool`, the
// driver, `ScriptMode`, and `ChatValidationHarness`. Its only jobs are choosing
// the mode, building the tool for the CLI path, printing the driver's output,
// and propagating its exit code.

import Foundation

/// The `shell-demo` executable's entry point: dispatches to `--chat` or
/// `--script` mode, or the default CLI mode, based on the first argument.
@main
enum ShellDemoMain {
    /// The flag selecting the live-model validation harness.
    private static let chatFlag = "--chat"
    /// The flag selecting the stdin batch driver.
    private static let scriptFlag = "--script"

    /// The name shown in usage/help text and error prefixes.
    private static let executableName = "shell-demo"

    /// Dispatches to `--chat`, `--script`, or the default CLI mode, based on
    /// `CommandLine.arguments`.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case chatFlag:
            await ChatValidationHarness.run()
        case scriptFlag:
            await ScriptMode.run()
        default:
            await runCLI(arguments: arguments)
        }
    }

    /// Drives `arguments` through an `OperationCLIDriver` over `ShellTool.make()`
    /// (rooted at `<cwd>/.shell`).
    ///
    /// Prints the driver's output (the dispatched operation's JSON, a corrective
    /// message, or ArgumentParser's own help/usage/error text) and exits with
    /// its code — a corrective-message run exits 0 (the operation returned
    /// rather than threw), a tool error or parse failure non-zero.
    ///
    /// - Parameter arguments: The command's arguments, excluding the executable
    ///   name.
    private static func runCLI(arguments: [String]) async {
        do {
            let driver = try ShellDemoDriver.make(executableName: executableName)
            let result = await driver.run(arguments: arguments)
            if !result.output.isEmpty {
                print(result.output)
            }
            if result.exitCode != 0 {
                exit(result.exitCode)
            }
        } catch {
            FileHandle.standardError.write(Data("\(executableName): \(error)\n".utf8))
            exit(1)
        }
    }
}
