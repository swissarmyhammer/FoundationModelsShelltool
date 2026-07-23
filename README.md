# FoundationModelsShelltool

[![CI](https://github.com/swissarmyhammer/FoundationModelsShelltool/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsShelltool/actions/workflows/ci.yml)

A virtual shell exposed as a single [FoundationModels](https://developer.apple.com/documentation/foundationmodels)
`Tool`: a model — or a command line — runs shell commands, reads their captured output back by
line, searches history, and manages long-running processes. It is a Swift port of the
[`swissarmyhammer`](https://github.com/swissarmyhammer/swissarmyhammer) shell tool built on
[`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool):
five operations (`execute command`, `list processes`, `kill process`, `grep history`,
`get lines`) are each declared once with `@Operation`, and both the model-facing `Tool` and a
dual-use CLI fall out of that declaration. Every command's output is captured to a per-session
log, so output that scrolls past the response tail stays retrievable by line number or regex.

Build the tool and register it on a session like any other FoundationModels `Tool`:

<!-- doc-snippet source="Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift" -->
```swift
let tool = try ShellTool.make()
let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
```
<!-- /doc-snippet -->

`ShellTool.make()` assembles a default history store rooted at `<cwd>/.shell`. A command denied
by the security policy, or a payload that can't be resolved to an operation, comes back as a
corrective message the model can retry within the turn — not a thrown error.

## Install

Add the package and depend on the `ShellTool` product. Requires the Swift 6.2 toolchain and the
macOS 26 SDK; the tool is **macOS-only** (it spawns children via `Subprocess` and runs `/bin/sh`).

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsShelltool.git", branch: "main")
```

## Getting started

The bundled `shell-demo` example drives the same five operations straight from the command line:

```console
$ swift run shell-demo command execute --command "echo hello"
$ swift run shell-demo history grep --pattern hello
$ swift run shell-demo lines get --command-id 1
```

## Waiting for slow commands

`execute command` takes an optional `waitSeconds` (CLI: `--wait-seconds`; default 30): how long to
wait for the command before returning with it still `running`. A command that hasn't finished when
`waitSeconds` elapses comes back with `status: "running"`, a `commandId` to poll or kill, and no
`exitCode` at all — the key is omitted, not `null`, until the command actually exits. `get lines`
takes its own `waitSeconds` and long-polls: when the requested range is still empty and the
command is still `running`, it keeps re-checking until a line lands, the command finishes, or its
own deadline elapses, instead of the caller burning a call on every re-ask.

A worked example — start a slow command with a short wait so it comes back `running`, keep reading
its output with a long-poll, then stop it:

```console
$ swift run shell-demo command execute --command "sleep 30" --wait-seconds 2
{"commandId":1,"status":"running","lines":0,"durationMs":2000,"output":[],"outputNote":"still running — use get lines (with waitSeconds to wait for more output), kill process to stop, list processes to check status"}

$ swift run shell-demo lines get --command-id 1 --wait-seconds 5
{"commandId":1,"first":0,"last":0,"lines":[],"status":"running"}

$ swift run shell-demo process kill --id 1
{"id":1,"command":"sleep 30","linesCaptured":0}
```

`timeout` and `waitSeconds` are two independent clocks: `timeout` bounds the child process itself
and keeps ticking even after a call has detached; `waitSeconds` only bounds how long one
`execute command`/`get lines` call waits before returning. See
[`DESIGN_NOTES.md`](DESIGN_NOTES.md) (§13, "Two clocks") for the full rationale.

## Documentation

- [Usage guide](docs/USAGE.md) — declaring operations, fusing them into a `Tool`, registering on
  a `LanguageModelSession`, and the CLI driver, with the five-operation reference.
- [Design & platform notes](DESIGN_NOTES.md) — where the port deliberately departs from the Rust
  original and the plan, with rationale.
