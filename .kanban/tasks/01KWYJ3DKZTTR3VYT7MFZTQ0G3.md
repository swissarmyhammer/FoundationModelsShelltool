---
comments:
- actor: claude-code
  id: 01kxkde834zqrssy6rfakyrybn
  text: 'Picked up by /finish (scoped-batch, no scope) after ShellPolicy ^e7rqj37 landed done. Starting iteration 1: /implement. Note the task''s own guidance — spike the process-group group-kill (risk §7.1) as the first RED/GREEN cycle before building out the runner; posix_spawn fallback if swift-subprocess can''t expose reliable pgid control.'
  timestamp: 2026-07-15T17:33:22.404754+00:00
- actor: claude-code
  id: 01kxkespgg9x5nx1h9mpyentrz
  text: |-
    Research done. swift-subprocess (beta.1, vendored in .build/checkouts) DOES expose process-group control: PlatformOptions.processGroupID maps to POSIX_SPAWN_SETPGROUP + posix_spawnattr_setpgroup on Darwin (Subprocess+Darwin.swift). Setting processGroupID = 0 makes the child its own group leader (pgid == pid), so killpg(pid, SIGKILL) takes down grandchildren. No posix_spawn fallback needed if the spike confirms.

    Key API: run(config, input:.none, output:.sequence, error:.sequence){ execution in ... } gives execution.processIdentifier.value (pid) and execution.standardOutput/standardError (SubprocessOutputSequence of raw Buffer). Configuration.run internally runs a monitor that calls cancelAsyncIO when the child terminates, so a body blocked reading a pipe an inherited grandchild holds open gets unblocked (no hang), and reapProcess reaps the direct child on every return path. terminationStatus: .exited(code) / .signaled(code) -> map signal death to -1 (parity Rust code().unwrap_or(-1)). Environment.inherit.updating([Key:String?]) overlays env on top of inherited (matches 'added on top of'). Rust OutputBuffer reference: crates/swissarmyhammer-tools/.../shell/infrastructure.rs (10MiB combined cap, find_safe_truncation_point line-boundary, null-in-first-8KiB binary -> '[Binary content: N bytes]', marker '\n[Output truncated - exceeded size limit]').

    Plan: spike pgid tree-kill first (RED with kill(pid) single-proc + no pgid; GREEN with processGroupID=0 + killpg), then TDD OutputBuffer, then the rest of the runner behaviors.
  timestamp: 2026-07-15T17:57:06.192563+00:00
- actor: claude-code
  id: 01kxkezc728b9ewrpfhaaybjyb
  text: |-
    SPIKE RESULT (risk §7.1): swift-subprocess handles process groups natively — NO posix_spawn fallback needed. RED/GREEN confirmed:
    - RED: spawned in caller's group + single-pid kill(pid) on timeout -> the `sh -c 'sleep N & sleep N'` tree left 2 survivors (test observed 2, asserted 0 -> fail). Leaked sleeps cleaned up with pkill.
    - GREEN: PlatformOptions.processGroupID = 0 (child becomes its own group leader, pgid==pid) + killpg(pid, SIGKILL) on timeout/defer/onCancel -> zero survivors, no leaked processes, run resolves status=timed_out exitCode=-1. Test timeoutGroupKillLeavesNoSurvivorsInProcessTree passes in ~2s.

    Design confirmed: run(config, input:.none, output:.sequence, error:.sequence){...} body; killpg driven from three sites (defer teardown, timeout task, onCancel handler); library reaps the direct child via reapProcess on return. Next: TDD OutputBuffer (10MiB cap / line-boundary truncation / binary placeholder), then wire real streaming + appendLines and add echo/exit/env/wd/truncation/binary/interleaving tests.
  timestamp: 2026-07-15T18:00:12.258003+00:00
- actor: claude-code
  id: 01kxkfgrc4e3w568pgmyn0cn2c
  text: |-
    Implementation landed. Files: Sources/ShellTool/ShellRunner.swift (spawn/stream/timeout/kill), Sources/ShellTool/OutputBuffer.swift (10MiB cap / line-boundary truncation / binary placeholder, port of Rust infrastructure.rs), Sources/ShellTool/ShellRunner.swift also holds a private OutputCollector actor that serializes the two concurrent stream readers into one OutputBuffer (enforces the shared cap without a data race). Tests: Tests/ShellToolTests/ShellRunnerTests.swift (12 tests) + OutputBufferTests.swift (9 tests).

    Milestones covered vs acceptance criteria: echo round-trip; exit 0/2/signal->-1 (all non-throwing successes); sleep-tree group-kill leaves zero survivors; truncation-at/over-cap with marker (unit + runner wiring via injectable maxOutputSize); binary placeholder; stdout-before-stderr interleaving with one shared counter (delegates to ShellState.appendLines); env added on top of inherited; working directory; requested-timeout kills well under the sleep and reports timed_out/-1; no timeout applied when none requested.

    Design notes / dead-ends:
    - Limits split confirmed: command-length (256KiB) and env-value (1024) live in ShellPolicy.check(command:)/check(environment:); the runner does NOT duplicate them (documented in run() doc). Only the 10MiB output cap is the runner's.
    - OutputBuffer line derivation must split on the \n BYTE, not String.split(on:"\n"): "\r\n" is a single Swift grapheme cluster so String.split does not break it (caught by a failing CRLF test) — matches ShellState.readLogLines.
    - Empty stream must emit zero log lines even when the shared binaryDetected flag is set by the OTHER stream (an empty stderr was emitting a spurious "[Binary content: 0 bytes]" line; guarded).
    - Non-clobber guard: run() only completeCommand when the record is still .running, so a future kill-op that sets .killed mid-run is not overwritten.

    Full `swift test`: 58 tests / 5 suites green; clean build (0 warnings); no leaked sleep processes after the run.
  timestamp: 2026-07-15T18:09:41.764779+00:00
- actor: claude-code
  id: 01kxkfwtvbk2cn5e2xcckwjhbh
  text: |-
    Double-check verdict: REVISE (advisory). Acting on findings:
    - Finding 1 (medium, real latent defect): the completion guard was a non-atomic check-then-act (listCommands read, then completeCommand write) across two ShellState actor hops — a concurrent kill-op could set .killed in the gap and get clobbered, so my "won't overwrite .killed" comment was a false guarantee. FIX: adding an atomic ShellState.completeIfRunning(commandId:status:exitCode:) (single actor hop) and calling it from the runner. This is the right home for the transition (ShellState owns `commands`).
    - Finding 2 (low, verification gaps): adding a default-cap constant test (defaultMaxOutputSize == 10MiB), and 8KiB binary-boundary tests (null just inside 8KiB flagged; just past NOT flagged). Zombie coverage: pgrep -f matches zombies too (they retain argv until reaped), so the existing survivors==0 already proves no survivors AND no zombies for the whole tree incl. the sh child — clarifying the test comment.
    - Note (out of scope, agreed): Rust's max_line_length=2000 is applied outside OutputBuffer and is not in this task's acceptance criteria; not ported here.
  timestamp: 2026-07-15T18:16:17.515419+00:00
- actor: claude-code
  id: 01kxkfzyj06ndgcjx5ham86wwk
  text: |-
    Double-check findings resolved and verified (advisory gate satisfied):
    - Finding 1 fixed: added atomic ShellState.completeIfRunning(commandId:status:exitCode:) (single actor hop, only transitions from .running); ShellRunner.run now calls it instead of the read-then-write guard. New ShellStateTests: completeIfRunningTransitionsARunningCommand + completeIfRunningLeavesAnAlreadyKilledCommandUntouched (the latter registers+killProcess->.killed, then asserts completeIfRunning is a no-op).
    - Finding 2 gaps closed: ShellRunnerTests.defaultOutputCapIsTenMiB (constant == 10MiB); OutputBufferTests.nullByteWithinFirst8KiBIsFlaggedBinary and nullBytePastFirst8KiBIsNotFlaggedBinary (the 8KiB sample-window boundary). Zombie coverage: documented that pgrep -f matches zombies (argv retained until reaped), so survivors==0 already proves no zombies for the whole tree incl. the sh child.

    Fresh `swift test`: 63 tests / 5 suites green; `swift build` 0 warnings; no leaked sleep processes. Leaving task in `doing` for /review (implement does not move to review).
  timestamp: 2026-07-15T18:17:59.616193+00:00
- actor: claude-code
  id: 01kxkg8hf10ny17zeq45a9bvz6
  text: 'Iteration 1: implementation landed green in `doing`. ShellRunner.swift (own process group via PlatformOptions.processGroupID=0, concurrent line capture via OutputCollector actor, optional timeout w/ group-kill → timed_out/-1, reap discipline on every path), OutputBuffer.swift (10MiB cap, line-boundary truncation marker, binary placeholder, lossy UTF-8), and ShellState.completeIfRunning added. swift-subprocess handled process groups natively — no posix_spawn fallback. /test re-confirmed green: 63 tests / 5 suites, 0 warnings, 0 skipped, no leaked processes. Committing checkpoint, then /review HEAD~1..HEAD.'
  timestamp: 2026-07-15T18:22:41.121277+00:00
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: doing
position_ordinal: '8180'
title: ShellRunner (spawn / stream / limits / timeout / kill)
---
## What
Implement `ShellRunner` in `Sources/ShellTool/ShellRunner.swift` using `swift-subprocess` to execute one command:

- Spawn `/bin/sh -c {command}` (plain `sh`, not a login shell — parity), stdin discarded, stdout/stderr piped.
- Place the child in its **own process group** via swift-subprocess's platform options (pgid = child), so `kill process` and timeout can `killpg(pid, SIGKILL)` and take down grandchildren. **This is the riskiest integration point (plan §7.1) — spike it first** with a `sh -c 'sleep 100 & sleep 100'` tree and confirm the whole tree dies on group-kill. If swift-subprocess can't expose reliable process-group control, fall back to a small posix_spawn wrapper (`POSIX_SPAWN_SETPGROUP`, pipes via file actions, `waitpid` off-actor) — same design, only the spawn call changes.
- Consume both streams concurrently, line-by-line, into an `OutputBuffer`: 10 MiB cap with line-boundary (UTF-8-safe) truncation + marker `[Output truncated - exceeded size limit]`; null-byte-in-first-8-KiB binary detection → `[Binary content: {n} bytes]`; UTF-8-lossy decoding; no ANSI stripping (stored raw, parity). Stdout lines append to the log first, then stderr, via one continuing counter (delegates to `ShellState.appendLines`).
- Working directory = request's `workingDirectory` or the session root; env vars are *added on top of* the inherited environment (not replacing it).
- **Timeout**: only if the caller requests one (no default) — race the child's completion against `Task.sleep`; on elapse, SIGKILL the process group, reap, record status `timed_out`, exit code `-1`.
- **Reap discipline**: every exit path (normal completion, timeout, external kill, task cancellation) must reap the child — guaranteed via `withTaskCancellationHandler` plus a `defer`'d teardown that group-kills and waits.
- Exit code taken from the child's termination status; signal death reported as `-1` (parity with Rust's `code().unwrap_or(-1)`).
- Command length ≤ 256 KiB and env value ≤ 1024 chars are runner-level input limits (validated here or accepted as pre-validated input from `ShellPolicy`, task 4 — confirm the split before implementing).

## Acceptance Criteria
- [ ] Echo round-trip: `sh -c "echo hi"` produces exit code 0 and one captured line `"hi"`
- [ ] Exit codes: 0, non-zero (e.g. 2), and signal death (`-1`) are all reported correctly and are NOT tool errors — a non-zero exit is a successful call
- [ ] `sleep 100 & sleep 100` tree is fully killed (no survivors, no zombies) when the runner's group-kill is invoked
- [ ] Output exactly at and just over the 10 MiB cap truncates at a line boundary with the marker
- [ ] Binary content in the first 8 KiB produces the `[Binary content: {n} bytes]` placeholder instead of raw bytes
- [ ] stdout/stderr interleaving is captured with stdout lines preceding stderr lines in the log, sharing one counter
- [ ] Env vars passed to the runner are added on top of, not replacing, the inherited environment
- [ ] No timeout is applied when none is requested; a requested timeout kills the group and reports `timed_out` / exit `-1`

## Tests
- [ ] `Tests/ShellToolTests/ShellRunnerTests.swift`: echo round-trip
- [ ] Exit code tests (0, 2, signal → -1)
- [ ] Env-add-on-top test
- [ ] Working directory test
- [ ] Process-tree kill test (`sleep 100 & sleep 100`, assert zero survivors via `pgrep`/`ps` after kill)
- [ ] Truncation-at-exactly-over-limit test
- [ ] Binary placeholder test
- [ ] Interleaved stderr ordering test
- [ ] Timeout test asserting wall-clock duration is well under the child's intended sleep time

## Workflow
- Use `/tdd`. Do the process-group spike (risk §7.1) as the first RED/GREEN cycle before building out the rest of the runner — if swift-subprocess can't do it, the posix_spawn fallback changes only the spawn call, not the tests above.