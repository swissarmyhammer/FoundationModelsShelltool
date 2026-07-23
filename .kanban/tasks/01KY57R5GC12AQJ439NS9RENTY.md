---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7n5p5zwfnz99yz4hy4v4wk
  text: |-
    Implemented via TDD (RED confirmed via compile failures / behavioral failures on the old batch-at-exit assertions, then GREEN).

    Changes:
    - Sources/ShellTool/OutputBuffer.swift: added cumulative `storedByteCount` (distinct from `totalBytesProcessed`) that `append()` now checks against `maxSize` instead of `currentSize`, so the cap keeps enforcing once lines start getting flushed out. Added `extractCompletedStdoutLines()`/`extractCompletedStderrLines()` (yield lines up to the last `\n`, leave the trailing partial line buffered; return `[]` once `binaryDetected`). Added `finish() -> FinalLines`: flushes each stream's trailing partial line, or (if binary) a single `[Binary content: N bytes]` line sized by the cumulative `storedByteCount`, or (if truncated) appends the truncation-marker as its own line. Old batch API (`stdoutLines`/`stderrLines`/`addTruncationMarker`) kept unchanged/untouched — still exercised by the pre-existing batch-mode tests.
    - Sources/ShellTool/ShellRunner.swift: replaced the `OutputCollector` actor with an `AsyncStream<StreamChunk>` funnel — both stream readers yield tagged chunks into one stream, and a single sequential consumer task (`consume`) extracts+flushes to `ShellState.appendLines` chunk-by-chunk, with no other caller ever touching the buffer or calling `appendLines` concurrently (avoids the actor-reentrancy mailbox-ordering hazard called out in the task). `finish()`'s trailing/marker lines are flushed once the stream ends. Task-group loop now waits for both stream-EOF AND the consumer's own completion before cancelling the timer.
    - Sources/ShellTool/ShellState.swift: updated `appendLines` doc for incremental/interleaved calls.
    - Sources/ShellTool/Operations/KillProcess.swift: updated `KillResult.linesCaptured` doc — no longer always 0 mid-stream.
    - DESIGN_NOTES.md: marked §8 "Batch-at-exit log append" as superseded (kept the historical text below, added a superseded note) — found via self-review that leaving it unedited would make the design notes describe removed behavior; `DesignNotesTests`' phrase-presence check still holds since "Batch-at-exit" stays in the heading.

    Tests added/updated:
    - Tests/ShellToolTests/OutputBufferTests.swift: incremental extraction (partial-line holdback), stderr independence, no-newline-yet, cumulative cap survives a flush, binary suppression on both streams, finish() trailing-line flush, finish() truncation-marker-as-line, finish() binary placeholder using cumulative count.
    - Tests/ShellToolTests/ShellRunnerTests.swift: replaced the old "stdout precedes stderr" test (that contract is explicitly superseded) with an alternating-write interleaving test using deliberate sleeps for determinism; added "lines visible while still running" and "kill mid-stream captures prior lines" (ShellRunner/ShellState level).
    - Tests/ShellToolTests/HistoryOpsTests.swift: added "grep history sees a running command's output before it finishes".
    - Tests/ShellToolTests/ProcessOpsTests.swift: updated the existing kill test's stale `linesCaptured:0` assertion (encoded the old batch contract) to `linesCaptured:1`, with a wait-for-flush poll before killing.

    Verification: `swift test` — 166 tests / 16 suites, 0 failures (ran fresh multiple times, including 3x back-to-back on the concurrency-sensitive suites to check for flakiness — all stable). Self-adversarial review done in place of the double-check subagent (Task tool unavailable in this environment) — traced the AsyncStream single-consumer funnel for reordering/cancellation/deadlock risks, cap accounting, and binary/truncation edge cases at finish(); the one real finding (stale DESIGN_NOTES.md) was fixed and re-verified green.

    Leaving in `doing` for review per the implement workflow.
  timestamp: 2026-07-23T14:13:19.167393+00:00
- actor: claude-code
  id: 01ky7rbyas24xge2cnczk0r2d4
  text: |-
    Resolved all 5 confirmed review findings (2026-07-23 09:21 checklist), root-cause fixed across the whole file per the review-findings rule:

    1. Sources/ShellTool/OutputBuffer.swift: deleted the entire dead batch-at-exit trimming path — addTruncationMarker(), makeRoom(for:), trimBuffer(_:neededSpace:), trimToLineBoundary(_:) — none had production callers post-incremental-refactor. Removed the one test that only existed to exercise addTruncationMarker() (truncationMarkerAppendedWhenTruncatedAndItFits in OutputBufferTests.swift); kept finishAppendsTheTruncationMarkerAsItsOwnLine, which exercises the current finish()-based truncation-marker path.
    2. Same file: redefined the `truncationMarker` static constant to be the plain marker line (dropped the leading "\n" prefix that only the now-deleted addTruncationMarker() needed) and made finish() use `Self.truncationMarker` instead of a duplicate string literal. Updated the doc comments on the constant and on finish() that referenced the deleted method.
    3. Sources/ShellTool/ShellRunner.swift: extracted `waitForCompletion(stdout:stderr:state:commandID:maxSize:timeout:pid:) -> Bool` (task-group setup + addTask calls + the streamsDone/consumerDone wait loop) and `finalizeResult(timedOut:terminationStatus:) -> (status:exitCode:)` (the if/switch after the subprocess result) out of `run`, which now just builds the config, runs the subprocess body via `waitForCompletion`, and finalizes. Had to move `timedOutFlag: Mutex<Bool>` from a `run`-level local into a local inside `waitForCompletion` itself and have it return `Bool` — passing a noncopyable `Mutex<Bool>` as a plain function parameter doesn't compile ("must specify ownership"); keeping it function-local and returning the flag avoids the ownership annotation entirely and is cleaner than borrowing.
    4. Same file: added `private static let outputStreamCount = 2` and replaced both magic-literal `2` comparisons in the wait loop.
    5. Sources/ShellTool/ShellState.swift: added `private static let defaultGrepResultLimit = 10` and changed `grep`'s `let cap = limit ?? 10` to use it; updated the doc comment.

    Verification: `swift build` clean (0 errors/warnings), `swift test` — 165 tests / 16 suites, 0 failures (166→165: the one addTruncationMarker-only test was removed, matching the task's "possibly with fewer tests" expectation). `mcp__sah__diagnostics check working` reports 0 errors/0 warnings.

    Leaving in `doing` per the implement workflow — ready for /review.
  timestamp: 2026-07-23T15:09:09.849250+00:00
position_column: doing
position_ordinal: '80'
title: 'Incremental output recording: stream lines into ShellState while a command runs'
---
## What

Replace the batch-at-exit append (DESIGN_NOTES §8) with incremental recording, so a still-running command's output is visible to `get lines`/`grep history` while it runs. This is the foundation for soft-deadline detach: a `running` result and a `get lines` long-poll are useless if no lines land until exit.

Files:
- `Sources/ShellTool/OutputBuffer.swift` — add an incremental completed-line extraction API: consuming appended chunks yields newly *completed* lines (text up to the last `\n`), keeping the trailing partial line buffered until more bytes or `finish`.
  - **Cap accounting must move to a cumulative stored-bytes counter** (flushed + still-buffered; distinct from `totalBytesProcessed`, which also counts dropped bytes). Today `available = maxSize - currentSize` where `currentSize` is bytes currently held — if flushing lines shrinks it, the 10 MiB cap silently stops enforcing and a chatty long-running command logs unbounded output. Once the cumulative counter hits `maxSize`, recording stops for good.
  - The truncation marker is emitted as a final *line* at `finish()` (not by trimming stored bytes — they may already be flushed); the binary placeholder's byte count uses the cumulative stored count. Binary nuance: once `binaryDetected` flips, stop yielding lines; at finish emit the single `[Binary content: N bytes]` placeholder line. (Lines flushed before detection stay in the log — record in the docs task.)
- `Sources/ShellTool/ShellRunner.swift` — `OutputCollector` (or its successor) flushes completed lines to `ShellState.appendLines` as chunks arrive, in arrival order. **Pin the flush topology**: line extraction and the `appendLines` call must happen in one isolation domain with *no suspension between extracting and appending* (extract inside the collector's method and `await state.appendLines` from that same method), or funnel all chunks through a single consumer (AsyncStream) — actors are reentrant and mailbox order is not a documented FIFO, so extract-here/append-elsewhere can reorder. Line-number assignment stays inside the `ShellState` actor. The stdout-then-stderr ordering contract becomes arrival-order interleaving. `finish()` still flushes the trailing partial line and the truncation-marker line.
- `Sources/ShellTool/ShellState.swift` — update `appendLines` doc contract (incremental, interleaved calls; counter continues across calls — the code already supports this).
- `Sources/ShellTool/Operations/KillProcess.swift` — `KillResult.linesCaptured` doc: now reports lines recorded so far, no longer always `0` for a mid-stream kill.

Keep `ExecuteCommand`'s tail assembly working unchanged (it reads stored lines after completion).

## Acceptance Criteria
- [x] While a command is still `running` (e.g. `sh -c 'echo one; sleep 30'`), `ShellState.getLines` returns the lines emitted so far
- [x] `ShellState.grep` also sees a running command's output (the other half of the §8 supersede)
- [x] Per-command line numbers remain monotonic 1-based across interleaved stdout/stderr appends; with deterministic alternating stdout/stderr output, stored order matches arrival order
- [x] A command emitting more than `maxSize` bytes incrementally stops recording at the cap mid-run (cumulative counter, not resident-bytes), and the truncation-marker line lands at finish
- [x] Binary detection: no further lines flushed after detection; single placeholder line with cumulative byte count at finish
- [x] `kill process` on a mid-stream command reports `linesCaptured > 0` when output preceded the kill
- [x] Completed-command behavior unchanged: `ExecuteResult` tail, `grep history`, `get lines` results identical for finished commands

## Tests
- [x] `Tests/ShellToolTests/OutputBufferTests.swift` — incremental extraction (partial line held back, completed on next chunk); cumulative cap enforced across incremental appends with flushing; binary suppression after detection; truncation-marker-as-line
- [x] `Tests/ShellToolTests/ShellRunnerTests.swift` — lines visible in `ShellState` while the child is still running; interleaving-order test with alternating stdout/stderr writes; mid-stream kill captures prior lines
- [x] `Tests/ShellToolTests/HistoryOpsTests.swift` — `grep` sees a running command's output
- [x] `Tests/ShellToolTests/ProcessOpsTests.swift` — `KillResult.linesCaptured > 0` for a command killed after emitting output
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running

## Review Findings (2026-07-23 09:21)

- [x] `Sources/ShellTool/OutputBuffer.swift:140` — addTruncationMarker() has no production callers. It is only exercised in OutputBufferTests.swift and was replaced by finish(), which handles truncation-marker appending inline. With the shift from batch-at-exit to incremental output recording, this method and its supporting helpers became dead. Delete addTruncationMarker() and its dependent helper methods (makeRoom, trimBuffer). The finish() method supersedes this entire pattern.
- [x] `Sources/ShellTool/OutputBuffer.swift:148` — makeRoom(for:) is a private helper called only by the dead addTruncationMarker() method. With addTruncationMarker() removed, this method becomes unreachable from production code. Delete makeRoom() as it serves only dead code.
- [x] `Sources/ShellTool/OutputBuffer.swift:154` — trimBuffer(_:neededSpace:) is a private static helper called only by the dead makeRoom() method. Removing makeRoom() leaves this method unreachable from production code. Delete trimBuffer() as it serves only dead code.
- [x] `Sources/ShellTool/OutputBuffer.swift:260` — Hardcoded truncation marker string '[Output truncated - exceeded size limit]' appears in the finish() method and duplicates the marker text from the truncationMarker constant (line 27, which includes a newline prefix). The non-newline variant should be extracted into a separate named constant to avoid duplication. Extract a constant: `private static let truncationMarkerLine = "[Output truncated - exceeded size limit]"`, then update line 260 to use `let marker = Self.truncationMarkerLine`.
- [x] `Sources/ShellTool/OutputBuffer.swift:324` — trimToLineBoundary(_:) is a private static helper called only by the dead trimBuffer() method. Removing trimBuffer() leaves this method unreachable from production code. Delete trimToLineBoundary() as it serves only the dead trimBuffer().
- [x] `Sources/ShellTool/ShellRunner.swift:69` — The `run` function has 4+ levels of nested control structures (withTaskCancellationHandler → Subprocess.run closure → withThrowingTaskGroup → while loop → switch statement), combined with complex task coordination logic tracking multiple state variables (streamsDone, consumerDone, timedOutFlag). The function is difficult to follow due to interacting async contexts and conditional branches scattered across nesting levels. Extract the task group coordination logic into a separate helper function (e.g., `private func waitForCompletion(...)`), and extract the result processing (if timedOut...else switch) into another helper. This reduces the main `run` function to a clear orchestration of three steps: start command, run subprocess with coordination, finalize result.
- [x] `Sources/ShellTool/ShellRunner.swift:165` — Hardcoded literal '2' representing the fixed count of output streams (stdout, stderr) appears twice (lines 165, 167) in the event-loop state machine and should be extracted into a named constant so the intent is explicit and changes are made in one place. Extract at the start of the method: `let expectedStreamCount = 2  // stdout + stderr`, then replace both occurrences with `expectedStreamCount`.
- [x] `Sources/ShellTool/ShellRunner.swift:167` — Hardcoded literal '2' (see line 165 — second occurrence of the same stream-count check). Use the same named constant as suggested for line 165.
- [x] `Sources/ShellTool/ShellState.swift:192` — Hardcoded default grep result limit '10' should be extracted into a named constant so the limit is discoverable and changes are made in one place. Extract a named constant: `private static let defaultGrepResultLimit = 10`, then use `let cap = limit ?? Self.defaultGrepResultLimit`.
