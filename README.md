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

## Documentation

- [Usage guide](docs/USAGE.md) — declaring operations, fusing them into a `Tool`, registering on
  a `LanguageModelSession`, and the CLI driver, with the five-operation reference.
- [Design & platform notes](DESIGN_NOTES.md) — where the port deliberately departs from the Rust
  original and the plan, with rationale.
