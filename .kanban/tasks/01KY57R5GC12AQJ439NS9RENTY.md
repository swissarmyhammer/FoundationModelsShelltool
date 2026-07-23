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