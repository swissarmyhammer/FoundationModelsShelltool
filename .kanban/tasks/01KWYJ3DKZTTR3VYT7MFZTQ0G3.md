---
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: todo
position_ordinal: '8280'
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