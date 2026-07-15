// `shell-demo` — example executable exercising the fused `shell` tool through
// the `OperationsCLI` command-tree driver.
//
// The full-stack analogue of the upstream `notes` executable (`NotesToolMain`):
// fuse the five operations into one tool with the contextless `ShellTool.make()`
// factory (which assembles a default `ShellContext` rooted at `<cwd>/.shell`),
// and drive argv through an `OperationCLIDriver` over that tool. The driver
// assembles the noun-verb grammar — `command execute`, `processes list`,
// `process kill`, `history grep`, `lines get` — from each operation's
// `@Operation(verb:noun:)`, with stock ArgumentParser handling help,
// did-you-mean, and completion scripts.
//
// This entry point is deliberately thin composition-root glue (like
// `NotesToolMain`): all dispatch and convergence logic lives in `ShellTool` and
// the driver, covered by `CLIConvergenceTests`. Its only jobs are building the
// tool, printing the driver's output, and propagating its exit code.

import Foundation
import OperationsCLI
import ShellTool

/// The `shell-demo` executable's entry point.
///
/// Fuses the shell operations over a default context with `ShellTool.make()`
/// (rooted at `<cwd>/.shell`) and drives `CommandLine.arguments` through an
/// `OperationCLIDriver`. Prints the driver's output (the dispatched
/// operation's JSON, a corrective message, or ArgumentParser's own help/usage/
/// error text) and exits with its code — a corrective-message run exits 0 (the
/// operation returned rather than threw), a tool error or parse failure
/// non-zero.
@main
enum ShellDemoMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let driver = try OperationCLIDriver(
                tool: try ShellTool.make(),
                executableName: "shell-demo"
            )
            let result = await driver.run(arguments: arguments)
            if !result.output.isEmpty {
                print(result.output)
            }
            if result.exitCode != 0 {
                exit(result.exitCode)
            }
        } catch {
            FileHandle.standardError.write(Data("shell-demo: \(error)\n".utf8))
            exit(1)
        }
    }
}
