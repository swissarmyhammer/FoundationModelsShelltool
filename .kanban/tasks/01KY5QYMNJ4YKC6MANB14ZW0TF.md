---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Process-group pid registry with parameterized exit sweep
---
## What

The no-leak backstop for detached commands, split out as a precursor so it lands and tests independently against today's blocking `ShellRunner.run` — before anything detaches.

Files:
- New `Sources/ShellTool/ProcessRegistry.swift` — a `nonisolated`-accessible, lock-based registry (`Mutex<Set<pid_t>>`, `Synchronization`) of live process-group leader pids, with `register(_:)`, `deregister(_:)`, and a **parameterized** sweep: `sweep(_ registry:)` `killpg`s every still-registered group. The process-global instance is wired ONLY inside an `atexit`-installed closure (installed once); tests always exercise private registry instances so the global sweep can never `killpg` pids belonging to concurrently running tests (swift-testing runs suites concurrently in one process).
- `Sources/ShellTool/ShellRunner.swift` — register the child's pid in the run body right after `state.registerProcess`, deregister on every exit path (the existing `defer` teardown site).

Doc the guarantee's limit honestly: `atexit` fires on normal process exit, not on SIGKILL or a crash — this narrows, not replaces, the per-run teardown.

## Acceptance Criteria
- [ ] `sweep(_:)` on a private registry with a live child pgid kills the group; already-dead pids are harmless (ESRCH)
- [ ] A completed `run(_:)` leaves the registry empty (registered during, deregistered after)
- [ ] The global registry is referenced only from the `atexit` closure; no test touches it
- [ ] Registry/sweep doc comments state the normal-exit-only limitation

## Tests
- [ ] `Tests/ShellToolTests/ShellRunnerTests.swift` (or a new `ProcessRegistryTests.swift`) — sweep kills a live private-registry child; register/deregister lifecycle across a run; ESRCH tolerance
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running