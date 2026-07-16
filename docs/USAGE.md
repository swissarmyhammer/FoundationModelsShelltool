# Using ShellTool

`ShellTool` is a virtual shell exposed as a single [FoundationModels](https://developer.apple.com/documentation/foundationmodels)
`Tool`, built on [`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool).
Five operations — `execute command`, `list processes`, `kill process`, `grep history`, and
`get lines` — are each declared once with `@Operation`, and both the model-facing `Tool` and a
dual-use CLI verb fall out of that single declaration. This guide walks the declare → fuse →
session → CLI path; the [design notes](../DESIGN_NOTES.md) cover where the port deliberately
diverges from the Rust original.

## Declare an operation

An operation is a `@Generable`, `@Operation`-annotated struct whose stored properties *are*
its parameters; its behavior lives in a separate `execute(in:)`. Here is `execute command`,
the tool's namesake operation:

<!-- doc-snippet source="Sources/ShellTool/Operations/ExecuteCommand.swift" -->
```swift
@Generable
@Operation(
    verb: "execute",
    noun: "command",
    description: "Execute a shell command with timeout and environment control"
)
internal struct ExecuteCommand {
    /// Number of trailing stored lines echoed back in the default response, so
    /// the common "run a command, read its tail" case is a single round-trip.
    /// Larger output is truncated to this tail; the full output stays available
    /// via `get lines`. Parity with the Rust `DEFAULT_TAIL_LINES`.
    static let tailLineCount = 32

    @Guide(description: "The shell command to execute")
    @OperationParam(short: "c")
    var command: String

    @Guide(description: "Seconds before killing the command (optional, default: none)")
    @OperationParam(short: "t")
    var timeout: Int?

    @Guide(description: "Working directory for command execution (optional, defaults to current directory)")
    @OperationParam(short: "w")
    var workingDirectory: String?

    @Guide(
        description:
            "Additional environment variables as a JSON string (optional, e.g. '{\"KEY1\":\"value1\",\"KEY2\":\"value2\"}')"
    )
    @OperationParam(short: "e")
    var environment: String?
}
```
<!-- /doc-snippet -->

`@Operation(verb:noun:)` names both the model op string (`"execute command"`) and the CLI
grammar (`command execute`); `@Guide` descriptions and `@OperationParam(short:)` flags carry
over to both surfaces. Each operation's `execute(in:)` runs against a shared `ShellContext`
that bundles the history store, the process runner, and the security policy.

## Fuse the operations into a Tool

`ShellTool.make(context:)` fuses the five operations into a single
`OperationTool<ShellContext>` sharing one context, so every op reads and records into the
same session store. The `inferOp` hook maps an omitted `op` to `execute command` — the Rust
dispatch's empty-op default:

<!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
```swift
public static func make(context: ShellContext) throws -> OperationTool<ShellContext> {
    try OperationTool(
        name: name,
        description: description,
        context: context,
        operations: [
            AnyOperation(ExecuteCommand.self),
            AnyOperation(ListProcesses.self),
            AnyOperation(KillProcess.self),
            AnyOperation(GrepHistory.self),
            AnyOperation(GetLines.self),
        ],
        resolver: OperationResolver(inferOp: { _ in ExecuteCommand.opString })
    )
}
```
<!-- /doc-snippet -->

`ShellContext` and `ShellState` are module-internal, so from outside the package use the
no-argument `ShellTool.make()`, which assembles a default context rooted at `<cwd>/.shell`
(falling back to a temp directory when the working directory is read-only). Pass
`preferredDirectory:` to point the store somewhere else — a hermetic test directory, say.

## Register with a `LanguageModelSession`

A fused `OperationTool` is a regular FoundationModels `Tool`, so it registers on a session
exactly like any other tool:

<!-- doc-snippet source="Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift" -->
```swift
let tool = try ShellTool.make()
let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
```
<!-- /doc-snippet -->

When the model's payload can't be resolved to a known operation (unknown op, missing
required parameter, unparseable value) — or when a command is rejected by `ShellPolicy` —
the tool *returns* a corrective message rather than throwing, so the model can rephrase
within the same turn; a throw would abort the turn. See
`Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift` for a scripted,
manual-run (`swift run shell-demo --chat`) validation of this end to end: op-call accuracy
over a prompt set, the fused schema's size via `tokenCount(for:)`, and the retry-cap
behavior on a deliberately policy-denied command.

## Drive the same operations from the CLI

`OperationCLIDriver` assembles a runtime ArgumentParser command tree from the fused tool's
operations, so the exact same declarations that serve the model also drive
`<executable> <noun> <verb> --options`. Build a driver over the fused tool:

<!-- doc-snippet source="Examples/ShellDemo/Sources/shell-demo/ShellDemoDriver.swift" -->
```swift
static func make() throws -> OperationCLIDriver {
    try OperationCLIDriver(tool: try ShellTool.make(), executableName: executableName)
}
```
<!-- /doc-snippet -->

then run argv through it and print the dispatched operation's JSON (the same payload the
model path produces):

<!-- doc-snippet source="Examples/ShellDemo/Sources/shell-demo/main.swift" -->
```swift
private static func runCLI(arguments: [String]) async {
    await ShellDemoDriver.run { driver in
        let result = await driver.run(arguments: arguments)
        if !result.output.isEmpty {
            print(result.output)
        }
        return result.exitCode
    }
}
```
<!-- /doc-snippet -->

Because the tree is built from real `ParsableCommand` types, `--help` at every level,
did-you-mean suggestions, `--opt=value`, combined short flags, and
`--generate-completion-script` all work as they would for a hand-written command tree. The
bundled `shell-demo` example wires exactly this up — try it end to end:

```console
$ swift run shell-demo command execute --command "echo hello"
$ swift run shell-demo history grep --pattern hello
$ swift run shell-demo lines get --command-id 1
$ swift run shell-demo --generate-completion-script zsh
```

`shell-demo` also has a `--script` mode that runs a batch of op lines against one shared
session over stdin, and the `--chat` live-model mode described above.

## The five operations

| Op | CLI grammar | What it does |
|----|-------------|--------------|
| `execute command` | `command execute` | Run a command under `ShellPolicy`, with an optional timeout, working directory, and extra environment; echoes the trailing 32 stored output lines. |
| `list processes` | `processes list` | List every command in the session with status, exit code, line count, start time, and duration. |
| `kill process` | `process kill` | Send `SIGKILL` to a running command's process group by id. |
| `grep history` | `history grep` | Regex- (or literal-) search recorded output, optionally scoped to one command; returns capped matches plus the full match count. |
| `get lines` | `lines get` | Read a command's stored output back by line-number range. |
