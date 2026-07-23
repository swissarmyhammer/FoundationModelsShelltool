---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7zjtwwy90ewztztxq8zywc
  text: |-
    Implemented via TDD.

    **RED**: Wrote `Tests/ShellToolTests/ProcessRegistryTests.swift` (register/deregister lifecycle, sweep-kills-a-live-child, ESRCH tolerance — all using the codebase's existing `posix_spawn`+`POSIX_SPAWN_SETPGROUP` pattern from `ShellStateTests.spawnKillableChild`) plus a new `runRegistersTheChildDuringExecutionAndDeregistersAfterCompletion` test in `ShellRunnerTests.swift`. Confirmed compile-fail RED (`cannot find 'ProcessRegistry' in scope`, `cannot find 'sweep' in scope`) via `swift build --build-tests`.

    **GREEN**: Added `Sources/ShellTool/ProcessRegistry.swift` — `final class ProcessRegistry: Sendable` wrapping `Mutex<Set<pid_t>>` (register/deregister/registeredPids), a parameterized top-level `func sweep(_ registry: ProcessRegistry)` that `killpg`s every registered pid (ESRCH silently tolerated, loop continues), and `ProcessRegistry.global` — a process-wide singleton wired to an `atexit` sweep installed exactly once (Swift's guaranteed-once global-init semantics), documented with the honest "normal exit only, not SIGKILL/crash" limitation. Wired `ShellRunner.run` to `registry.register(pid)` right after `state.registerProcess` and `registry.deregister(pid)` in the existing `defer` teardown alongside the `killpg`.

    **Design decision**: `ShellRunner.registry` defaults to `.global` (production parity, mirrors `ShellContext`'s existing default-parameter style) — but per the acceptance criterion "no test touches [the global registry]", every test call site across `ShellRunnerTests.swift` and `HistoryOpsTests.swift` was updated to pass an explicit private `ProcessRegistry()` (via `makeRunner(registry:)`'s own fresh-per-call default, or inline `registry: ProcessRegistry()`), so nothing in the test suite ever defaults to `.global` even implicitly. `ProcessRegistry.global` itself is referenced only from its own file's `atexit` installer and its own accessor.

    **Adversarial self-review note**: No `Task`/subagent tool was available in this environment to spawn the `double-check` agent per really-done's advisory gate, so I substituted a rigorous self-adversarial pass instead. That pass is what caught the "no test touches it" gap above (initially only the *new* registry tests used private instances; the pre-existing `ShellRunner(state:)` call sites in `HistoryOpsTests.swift` and one in `ShellRunnerTests.swift` would have silently defaulted to `.global`) — fixed by threading an explicit private registry through every test call site.

    **Final verification**: `swift build --build-tests` clean, zero warnings. `swift test` (fresh run): 182 tests, 17 suites, all passed, exit 0. No failures anywhere in output.

    Task left in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-23T17:15:15.740292+00:00
position_column: doing
position_ordinal: '80'
title: Process-group pid registry with parameterized exit sweep
---
## What

The no-leak backstop for detached commands, split out as a precursor so it lands and tests independently against today's blocking `ShellRunner.run` — before anything detaches.

Files:
- New `Sources/ShellTool/ProcessRegistry.swift` — a `nonisolated`-accessible, lock-based registry (`Mutex<Set<pid_t>>`, `Synchronization`) of live process-group leader pids, with `register(_:)`, `deregister(_:)`, and a **parameterized** sweep: `sweep(_ registry:)` `killpg`s every still-registered group. The process-global instance is wired ONLY inside an `atexit`-installed closure (installed once); tests always exercise private registry instances so the global sweep can never `killpg` pids belonging to concurrently running tests (swift-testing runs suites concurrently in one process).
- `Sources/ShellTool/ShellRunner.swift` — register the child's pid in the run body right after `state.registerProcess`, deregister on every exit path (the existing `defer` teardown site).

Doc the guarantee's limit honestly: `atexit` fires on normal process exit, not on SIGKILL or a crash — this narrows, not replaces, the per-run teardown.

## Acceptance Criteria
- [x] `sweep(_:)` on a private registry with a live child pgid kills the group; already-dead pids are harmless (ESRCH)
- [x] A completed `run(_:)` leaves the registry empty (registered during, deregistered after)
- [x] The global registry is referenced only from the `atexit` closure; no test touches it
- [x] Registry/sweep doc comments state the normal-exit-only limitation

## Tests
- [x] `Tests/ShellToolTests/ShellRunnerTests.swift` (or a new `ProcessRegistryTests.swift`) — sweep kills a live private-registry child; register/deregister lifecycle across a run; ESRCH tolerance
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running