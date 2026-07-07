---
position_column: todo
position_ordinal: '80'
title: Package scaffolding
---
## What
Create `Package.swift` for the Swift package `FoundationModelsShelltool`: swift-tools-version 6.2, platform `.macOS(.v26)` only (no iOS — `Process`/posix_spawn and `/bin/sh` don't exist on iOS).

Dependencies:
- `FoundationModelsOperationTool` at `git@github.com:swissarmyhammer/FoundationModelsOperationTool.git`, branch `main` — products `Operations`, `OperationsCLI`
- `apple/swift-subprocess`
- `jpsim/Yams`

Targets, mirroring the upstream root-package layout (Examples as targets of the root `Package.swift`):
- `Sources/ShellTool` — library target (ops, `ShellContext`, `ShellState`, `ShellRunner`, `OutputBuffer`, `ShellPolicy`, output types), depends on `Operations`, `Subprocess`, `Yams`
- `Examples/ShellDemo/Sources/shell-demo` — executable target, depends on `ShellTool`, `Operations`, `OperationsCLI`
- `Tests/ShellToolTests` — test target, depends on `ShellTool` (`@testable`)

Add `.github/workflows/ci.yml` running `swift build && swift test` on a macOS 26 runner. Confirm root `.gitignore` covers `.build/` (already present) — no `.shell/`-specific top-level entry is needed since the runtime directory self-ignores via its own nested `.gitignore` (see `ShellState` in task 2).

## Acceptance Criteria
- [ ] `swift build` succeeds with all three targets resolving
- [ ] `swift package resolve` pulls `FoundationModelsOperationTool`, `swift-subprocess`, and `Yams` cleanly
- [ ] CI workflow file exists and is syntactically valid

## Tests
- [ ] A placeholder test in `Tests/ShellToolTests` (e.g. `XCTAssertTrue(true)` or a Swift Testing `@Test` stub) passes via `swift test`

## Workflow
- Use `/tdd` — write the placeholder test first, then wire the manifest to make `swift test` pass.