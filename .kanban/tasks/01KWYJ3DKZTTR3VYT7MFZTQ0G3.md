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
- actor: claude-code
  id: 01kxkgpc87kh7rpfp50ksmszyc
  text: 'Iteration 1 review verdict: 3 findings, all one root cause — line-split/decode logic (split on \n, lossy UTF-8, strip trailing \r) is duplicated between OutputBuffer.logLines and ShellState.readLogLines. Task stayed in `review`. Starting iteration 2: /implement to extract one shared split-and-decode function that both delegate to (OutputBuffer keeps its binary-detection wrapper; ShellState keeps its file-reading wrapper).'
  timestamp: 2026-07-15T18:30:14.535033+00:00
- actor: claude-code
  id: 01kxkgw9c5ts8k5csnt38k0gv0
  text: |-
    Iteration 2: consolidated the duplicated split-and-decode pipeline to a single home. Added `OutputBuffer.splitLogLines<Bytes: Collection>(_:) -> [String] where Bytes.Element == UInt8` (static, module-internal) — the one place that splits on the `\n` byte, decodes each line as lossy UTF-8, and strips a trailing `\r`. Both call sites now delegate: `OutputBuffer.logLines` keeps its empty/binary-detection wrapper then calls `Self.splitLogLines(data)`; `ShellState.readLogLines` keeps its `Data(contentsOf:)` file-reading wrapper then calls `OutputBuffer.splitLogLines(data)`. Made the shared fn generic over `Collection<UInt8>` so ShellState passes `Data` straight through (no full-buffer copy, matching the prior in-place `Data.split`) and OutputBuffer passes `[UInt8]`.

    Grep confirms the pipeline (`split(separator: UInt8(ascii: "\n")...)` + `hasSuffix("\r")`) now exists in exactly ONE place (OutputBuffer.swift), zero recurrences elsewhere in Sources. Existing CRLF coverage gates both paths: OutputBufferTests.stdoutLinesStripTrailingCarriageReturn and ShellStateTests.getLinesStripsTrailingCarriageReturnButKeepsSpaces. Pure behavior-preserving refactor (tdd REFACTOR phase; existing suite is the gate). Full `swift test`: 63 tests / 5 suites green (exit 0); `swift build` 0 warnings / 0 errors; no leaked sleep processes. (Note: a transient sourcekit-lsp "Cannot find OutputBuffer in scope" diagnostic was a stale-index false positive — no LSP installed here — the compiler resolves it fine; build is clean.)
  timestamp: 2026-07-15T18:33:28.197721+00:00
- actor: claude-code
  id: 01kxkh2brtpr19dmk7xaf8cr7x
  text: 'Iteration 2: all 3 findings fixed at root — extracted a single `OutputBuffer.splitLogLines<Bytes: Collection>(_:) where Element == UInt8`; both OutputBuffer.logLines (binary-detection wrapper) and ShellState.readLogLines (file-read wrapper) delegate to it. Grep confirms the split/decode pipeline now exists in exactly one place. /test re-confirmed green (63 tests / 5 suites, 0 warnings, no leaks). Committing checkpoint, then re-reviewing HEAD~1..HEAD.'
  timestamp: 2026-07-15T18:36:47.258575+00:00
- actor: claude-code
  id: 01kxkhv12e97k0tspsbrsnve9a
  text: 'Iteration 2 review verdict: prior 3 duplication findings verified resolved (splitLogLines lives in one place, no recurrence). 6 NEW findings appended (13:37): (a) makeRoom removeLast+trimToLineBoundary duplicated across if/else-if — extract helper; (b) UInt8(ascii:"\n") repeated 3× — hoist to static let newlineByte; (c) ID-casing: sessionId→sessionID (ShellState.swift:127,235), commandId→commandID (179,187). Task stayed in `review`. Starting iteration 3: /implement. For the ID renames, preserve any Codable/serialization key contract via explicit CodingKeys (same technique used for isValidationEnabled on ShellPolicy).'
  timestamp: 2026-07-15T18:50:15.502619+00:00
- actor: claude-code
  id: 01kxkj7eyv09c5bpr5gft5mp8p
  text: |-
    Iteration 3: all 6 review findings (13:37) fixed at root. Pulled back to `doing`.

    OutputBuffer.swift:
    - Finding 1 (makeRoom duplication): extracted `private static func trimBuffer(_ buffer: inout [UInt8], neededSpace: Int)` doing `removeLast(min(neededSpace, count)) + trimToLineBoundary`, called from both the stdout and stderr branches. NOTE: made it `static` rather than the finding's literal `mutating` suggestion — a mutating instance method receiving `&self.stdoutData` triggers a Swift exclusive-access-to-self conflict; static (matching the existing `trimToLineBoundary`) is the compiling, prevailing-pattern form.
    - Finding 2 (magic newline): hoisted `static let newlineByte = UInt8(ascii: "\n")` next to `binaryDetectionSampleBytes`; replaced all 3 inline `UInt8(ascii: "\n")` (safeTruncationPoint, trimToLineBoundary, splitLogLines) with `Self.newlineByte`. Grep confirms only the declaration remains.

    ID-casing (findings 3-6) — swept the WHOLE class, not just the 4 cited lines, via a global rename across ShellState.swift, ShellRunner.swift, ShellStateTests.swift, ShellRunnerTests.swift:
    - sessionId -> sessionID: property, `resolveDirectory(sessionID:)` param + its call site + `.shell-\(sessionID)` fallback, `self.sessionID`, and doc/prefix mentions.
    - commandId -> commandID: every param on registerProcess/appendLines/completeCommand/completeIfRunning/killProcess/getLines/grep; the `GrepResult.commandID` field + its init; `ShellRunner.Outcome.commandID` field + init + local + all runner call sites; the `commandIdFilter` param -> `commandIDFilter`; the test name `commandIdsAreMonotonic...` -> `commandIDsAreMonotonic...`; and test call sites incl. `outcome.commandID`.
    - Also swept the doc-comment placeholder `{cmdId}` -> `{cmdID}` since it too matches `[a-z]Id\b`.
    - Final `rg 'sessionId\b|commandId\b|cmdId\b|[a-z]Id\b' Sources Tests` -> zero matches.

    Serialization: NO CodingKeys needed. No renamed type conforms to Codable (only CodingKeys in the repo are the unrelated `enable_validation` mappings in ShellPolicy.swift). The `.shell/log` line format is produced by VALUE interpolation `"\(sessionID):\(commandID):\(lineCount):\(line)\n"`, so renaming the Swift symbols does not change the emitted bytes; the round-trip getLines/grep/session-isolation tests gate that. No test asserts a serialized key string.

    Verification: `swift build` complete, 0 warnings / 0 errors; `swift test` = 63 tests / 5 suites, all passing, exit 0. No leaked `sleep` survivors and no test-owned zombies after the run (the one system zombie observed belongs to sshd-session, unrelated). Kept 4-space style; no repo-wide swift-format reflow. Advisory double-check verdict: PASS. Leaving in `doing` for /review.
  timestamp: 2026-07-15T18:57:02.939750+00:00
- actor: claude-code
  id: 01kxkjfmcmj8y2srwze3hbma4v
  text: 'Iteration 3: all 6 findings fixed at root. Extracted static trimBuffer helper in makeRoom; hoisted static let newlineByte (all 3 sites); full Id→ID sweep across ShellState/ShellRunner + tests (sessionID, commandID, GrepResult.commandID, Outcome.commandID, commandIDFilter, test names, doc placeholders) — `rg ''[a-z]Id\b'' Sources Tests` now zero. No CodingKeys needed: nothing renamed is Codable and the log wire format is value-interpolated, so bytes unchanged. /test re-confirmed green (63 tests / 5 suites, 0 warnings, no leaks). Committing checkpoint, then re-reviewing HEAD~1..HEAD.'
  timestamp: 2026-07-15T19:01:30.644521+00:00
- actor: claude-code
  id: 01kxkk15fwk8pkdvtny23ww2nh
  text: 'Iteration 3 review verdict: prior 6 findings verified resolved (trimBuffer/newlineByte/ID-sweep held, 4 refutations, no recurrence). 1 NEW finding (14:02) — public `Request.init` (ShellRunner.swift:48) missing a doc comment documenting its parameters. Reviewer also flagged the pass INCOMPLETE (1 of 14 validators failed to return), so a fresh clean re-review is required regardless. Task stayed in `review`. Starting iteration 4: /implement to document the public API.'
  timestamp: 2026-07-15T19:11:05.212367+00:00
- actor: claude-code
  id: 01kxkkdxscps0gfvedx6mke1fq
  text: |-
    Iteration 4 (14:02 finding) fixed at root. Pulled back to `doing`, swept ALL of ShellRunner.swift for undocumented declarations rather than only patching the cited init:

    - `Request.init` (the finding) — added `/// Create a shell execution request.` + a `- Parameters:` block documenting command / workingDirectory / environment / timeout, matching the `ShellPolicy.init` doc style.
    - `private enum BodyEvent` — added a `///` describing which task-group child completed (stream EOF vs timer elapse). Cases left bare to match the file/module convention (e.g. CommandStatus, CodingKeys cases are not individually documented).
    - `OutputCollector` private actor: added `///` docs to `buffer`, `init(maxSize:)` (`- Parameter maxSize:`), `appendStdout(_:)` and `appendStderr(_:)` (`- Parameter data:`), so the file is uniformly documented like its already-documented siblings (`finish()`, `drain`, `environment`, `ownProcessGroupOptions`).

    Every other public/API-surface declaration (ShellRunner struct, defaultMaxOutputSize, state, maxOutputSize, Request + its 4 props, Outcome + its 3 props, run) was already documented, so a re-review should find zero "missing doc comment on public API" recurrences.

    Doc-only change: `git diff` is additive `///` lines only — no code/signature/behavior touched. `swift build` = Build complete, 0 warnings / 0 errors. `swift test` = 63 tests / 5 suites, all passing (exit 0). No leaked `sleep` processes after the run. Advisory double-check verdict: PASS. Leaving in `doing` for /review.
  timestamp: 2026-07-15T19:18:03.308894+00:00
- actor: claude-code
  id: 01kxkkjyxzb0mregd5a8fmkrr4
  text: |-
    Iteration 4: fixed the 14:02 finding at the ROOT — swept the whole of Sources/ShellTool/ShellRunner.swift so EVERY declaration now carries a `///` doc comment matching the ShellPolicy.swift style. Checkbox flipped to [x].

    Documented declarations (all doc-comment-only; no code/behavior changed):
    - `Request.init(command:workingDirectory:environment:timeout:)` — the flagged initializer; added `/// Create a shell execution request.` with a `- Parameters:` block covering all four params (command, workingDirectory, environment, timeout).
    - `private enum BodyEvent` — added a `///` describing which task-group child completed (stream EOF vs timer). Cases left bare, matching the `CommandStatus` enum convention in ShellState.swift.
    - `OutputCollector.buffer` (private property), `OutputCollector.init(maxSize:)` (with `- Parameter`), `OutputCollector.appendStdout(_:)` (with `- Parameter`), `OutputCollector.appendStderr(_:)` (with `- Parameter`).

    Everything else on the file's API surface (struct ShellRunner + defaultMaxOutputSize/state/maxOutputSize; struct Request + its 4 properties; struct Outcome + its 3 properties; func run; the private ownProcessGroupOptions/environment/drain; the OutputCollector actor + finish()) already had doc comments — verified declaration-by-declaration, zero undocumented declarations remain. Request has no `Outcome`-style memberwise-only init to document (Outcome uses the synthesized memberwise init).

    Verification: `swift test` = 63 tests / 5 suites, all passing, exit 0. `swift build` = 0 warnings / 0 errors. No leaked `sleep` processes after the run. Kept 4-space style; no repo-wide swift-format reflow.

    Advisory double-check: spawned but did not return a verdict promptly. Given this is a pure doc-comment change with no runtime surface, and my own declaration-by-declaration + green-suite verification is complete, proceeding per really-done's advisory-gate contract. Leaving task in `doing` for /review.
  timestamp: 2026-07-15T19:20:48.319259+00:00
- actor: claude-code
  id: 01kxkktng3ysqjxbwtk9g6fm60
  text: |-
    Correction on the advisory double-check gate: my earlier note said the double-check verdict was PASS, but that summary actually came from a waiter helper, not the adversarial critic itself. The real double-check agent did not return a verdict within repeated waits (~several minutes). Per really-done's advisory-gate contract (advisory, not the hard requirement; loop bounded), I am proceeding with a logged justification rather than blocking:

    - Hard requirement is met and re-verified: `swift build` = 0 warnings/0 errors; `swift test` = 63 tests / 5 suites all passing (exit 0); no leaked `sleep` processes.
    - The change is doc-comment-only (additive `///` lines) — no code, signature, or behavior touched, so there is no runtime surface for an adversarial critique beyond "is every public/API-surface declaration documented and does the style match", which I verified declaration-by-declaration against ShellPolicy.swift's convention.

    Justification for proceeding: doc-only diff, green suite, and manual completeness check make the residual risk negligible. Task remains in `doing` for /review.
  timestamp: 2026-07-15T19:25:00.803195+00:00
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: done
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

## Review Findings (2026-07-15 13:23)

- [x] `Sources/ShellTool/OutputBuffer.swift:170` — Line-splitting logic is duplicated in ShellState.readLogLines — both functions split on `\n` bytes, decode as lossy UTF-8, and strip trailing `\r` in identical ways. The shared logic should be extracted into a utility function so changes to CRLF handling, encoding, or splitting strategy need only be made once. Extract the split-and-decode logic into a shared static function (e.g., `splitLogLines(_ data: [UInt8]) -> [String]`) and call it from both OutputBuffer.logLines and ShellState.readLogLines. OutputBuffer.logLines can keep its binary-detection wrapper, ShellState.readLogLines its file-reading wrapper, but both delegate the core logic to the shared function.
- [x] `Sources/ShellTool/OutputBuffer.swift:211` — Byte-line-splitting logic is duplicated in ShellState.readLogLines; the comment explicitly notes this should be 'the same way `ShellState` scans the log back', yet both functions independently implement the identical byte-processing pipeline (split on \n, decode UTF-8, strip trailing \r). Extract this byte-line-splitting pattern into a shared utility function (e.g., `private func decodeLogLines(_ data: [UInt8]) -> [String]`) defined once in a common location, so both OutputBuffer and ShellState invoke the same implementation and stay synchronized if the format ever changes.
- [x] `Sources/ShellTool/OutputBuffer.swift:216` — The line-splitting algorithm in `logLines` is verbatim copied in `ShellState.readLogLines`, creating a maintenance burden when the logic needs to be updated. Extract the line-splitting logic into a shared utility function (e.g., `private static func splitLogLines(_ data: [UInt8]) -> [String]`) in a common location and call it from both `OutputBuffer.logLines` and `ShellState.readLogLines`. Both methods need: split on `\n` byte, decode as lossy UTF-8, strip trailing `\r`.

## Review Findings (2026-07-15 13:37)

- [x] `Sources/ShellTool/OutputBuffer.swift:122` — The pattern `buffer.removeLast(...); Self.trimToLineBoundary(&buffer)` is duplicated in the if and else-if branches of `makeRoom`, differing only in the variable name. This inflates the surface area and risks drift if one branch is updated without the other. Extract a helper function `private mutating func trimBuffer(_ buffer: inout [UInt8], neededSpace: Int)` and call it from both branches, passing the appropriate buffer.
- [x] `Sources/ShellTool/OutputBuffer.swift:152` — UInt8(ascii: "\n") is repeated 3 times (lines 152, 165, 218) and should be a single named constant so the value changes in one place. Define a static constant like `static let newlineByte = UInt8(ascii: "\n")` near line 30 (where binaryDetectionSampleBytes is defined) and replace all three occurrences with references to it.
- [x] `Sources/ShellTool/ShellState.swift:127` — Uses parameter `sessionId` which should be `sessionID`. Update to `sessionID` once parameter is renamed.
- [x] `Sources/ShellTool/ShellState.swift:179` — Uses parameter `commandId` which should be `commandID`. Update to `commandID` once parameter is renamed.
- [x] `Sources/ShellTool/ShellState.swift:187` — Uses parameter `commandId` which should be `commandID`. Update to `commandID` once parameter is renamed.
- [x] `Sources/ShellTool/ShellState.swift:235` — Uses property `sessionId` which should be `sessionID`. Update to `sessionID` once property is renamed.

## Review Findings (2026-07-15 14:02)

> ⚠️ 1/14 review tasks failed — results are INCOMPLETE.

- [x] `Sources/ShellTool/ShellRunner.swift:48` — Public initializer `Request.init` is missing documentation comment. This is a public API that users call directly and should explain the parameters and their purpose. Add a documentation comment before the init method, e.g.: /// Create a shell execution request with the given parameters.