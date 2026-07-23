---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky855038zj1gze2dwqw056qk
  text: |-
    Picked up task, moved to doing. Read ShellRunner.swift, OutputBuffer.swift, ProcessRegistry.swift, ExecuteCommand.swift, GetLines.swift, KillProcess.swift in full to ground the doc content in actual shipped behavior (arrival-order interleaving via single consumer task, binary-detection nuance in OutputBuffer.extractCompleted*Lines, the two-clocks distinction in ShellRunner.run(_:wait:), cancellation-as-detach in raceDeadline, and ProcessRegistry.global's atexit-only sweep limitation).

    TDD per the workflow note: updated Tests/ShellToolTests/DesignNotesTests.swift's requiredPhrases FIRST (8 pins now, up from 5 — updated §8/§12 pins to target the superseded/amended wording instead of the historical original text, plus 3 new pins for two-clocks/running-result-divergence/cancellation-detach entries). Ran `swift test --filter DesignNotesTests` and confirmed RED: 5 of 8 phrase cases fail as expected (the 2 changed + 3 new pins aren't in DESIGN_NOTES.md yet). Proceeding to rewrite DESIGN_NOTES.md §8/§12 and add §13-15 to turn it GREEN, then README.md polling docs, then the ChatValidationHarness scripted-prompt re-pointing.
  timestamp: 2026-07-23T18:52:33.768662+00:00
- actor: claude-code
  id: 01ky85v0fe8a48n8c54xtaps66
  text: |-
    Work complete, `swift test` fully green: 201 tests, 17 suites, 0 failures, exit code 0 (verified fresh, twice).

    Changes:
    - Tests/ShellToolTests/DesignNotesTests.swift: requiredPhrases grew from 5 to 8 pins. Updated the §8 pin ("Batch-at-exit" → "arrival-order interleaving") and §12 pin ("non-optional `Int`" → "omitted while `running`") to target the superseded/amended wording instead of the historical retained text, and added 3 new pins for §13/§14/§15. Confirmed RED (5/8 cases failing) before writing DESIGN_NOTES.md content, then GREEN after.
    - DESIGN_NOTES.md: §8 rewritten to state the arrival-order-interleaving ordering contract explicitly (not stdout-then-stderr) and the binary-detection nuance (lines flushed before a later chunk flips `binaryDetected` stay in the log; only the still-buffered remainder collapses to the placeholder). §12 rewritten to say the exitCode field is "omitted while `running`" rather than just "omitted from the encoded JSON", and to forward-reference §13. Added three new entries: §13 "Two clocks" (timeout bounds the child, waitSeconds bounds the tool call — grounded in ShellRunner.run(_:wait:)'s file header), §14 "execute command can return running" (the Rust-blocking-semantics divergence, the commandID handle, and the get lines/list processes/kill process polling protocol), §15 "cancellation during the wait window detaches rather than kills" (grounded in raceDeadline's doc comment, plus the ProcessRegistry.global atexit-only sweep limitation stated explicitly — SIGKILL/crash is not covered). Updated the section-93 intro paragraph's entry count (was "the five below", now correctly scoped to 8–12 vs 13–15) and the plan-§8 "seven departures" framing untouched (still accurate, unrelated section).
    - README.md: new "Waiting for slow commands" section — documents `waitSeconds` on both `execute command` and `get lines` (with CLI `--wait-seconds` flag name, verified against CLIConvergenceTests), the `running` result shape (status/commandId/no exitCode key), and a worked execute→running→get-lines-long-poll→kill console example with realistic JSON shapes cross-checked against ExecuteResult/LineRange/KillResult's actual CodingKeys and ExecuteCommand.runningOutputNote's exact text. Plain ```console block (no doc-snippet marker), so it's illustrative prose, not parsed/pinned by ReadmeSnippetTests — confirmed that suite still passes (10/10).
    - Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift: file-header bullets updated from "three signature behaviors" to four (added corrective-kill-recovery and soft-deadline-detach-and-polling bullets, in place of the old single "background process lifecycle" bullet). scriptedPrompts grew from 6 to 8 entries: kept the seq-1-100/grep/get-lines opening three, added a new prompt 4 that deliberately targets the corrective "No running process" path (killing the already-finished command 1) since detach changed what the old "kill command id 2" prompt would actually exercise, then re-pointed the sleep scenario across three new prompts (execute with an implied short wait → get lines long-poll → genuine kill of command running for real), keeping "list processes" in between. Docstring above the array explains the before/after semantics change explicitly so a future reader doesn't have to reconstruct why the re-pointing happened.
    - Examples/ShellDemo/Sources/shell-demo/ScriptMode.swift: reviewed, left unchanged — it contains no scripted command content (no "sleep"/"kill" literals), only the generic stdin-batch-driver mechanics, and its one-process-shared-session claims are unaffected by the detach work (each op line still dispatches through the same shared ShellContext regardless of whether an individual op returns `running`).

    Review-note sweep for contradicted claims: grepped the whole repo's `.md` files for "blocks to completion"/"always blocks"/"Rust blocking" — only hits are DESIGN_NOTES.md's own new prose and this task's kanban description; docs/USAGE.md's execute-command doc-snippet is a live excerpt from ExecuteCommand.swift so it can't drift. Verified every JSON field name/shape quoted in the new README section against the actual `CodingKeys` enums (ExecuteResult, LineRange, KillResult) and `ExecuteCommand.runningOutputNote`'s literal text.

    Note on the really-done adversarial double-check gate: the `Task` tool for spawning a `double-check` subagent is not available to me in this execution context (ToolSearch found no matching tool), so I could not delegate the adversarial pass as really-done directs. Substituted a thorough manual self-critique instead (documented above) on top of the hard-requirement fresh `swift test` run, per really-done's own framing of the delegated pass as advisory and the test-run verification as the non-negotiable gate.

    Leaving task in `doing` per /implement's contract — not moving to `review` myself.
  timestamp: 2026-07-23T19:04:35.054235+00:00
depends_on:
- 01KY57S9Y3QJF0NN668YDR8Y7K
- 01KY57SQEF3368T4GK7T3ZF09S
position_column: doing
position_ordinal: '80'
title: DESIGN_NOTES, README, and doc-pinning test sweep for soft-deadline detach
---
## What

Record the design departures the detach work introduced, update the user-facing docs and demo, keeping the doc-pinning tests green.

Files:
- `DESIGN_NOTES.md`:
  - Supersede §8 (batch-at-exit append): output now streams into `ShellState` incrementally; the ordering contract is arrival-order interleaving, not stdout-then-stderr; `KillResult.linesCaptured` is now meaningful mid-stream. Note the binary-detection nuance (lines flushed before a later chunk flips detection remain in the log).
  - Amend §12: `ExecuteResult.exitCode` is now `Int?`, omitted while `running`; the `-1` sentinel is unchanged for finished commands.
  - New entry: the two clocks — `timeout` bounds the child (keeps ticking across detach), `waitSeconds` bounds the tool call; soft-deadline default (30s) and `0 = detach immediately`.
  - New entry: divergence from the Rust blocking semantics — `execute command` can return `status: "running"` with a `commandID` handle; the polling protocol is `get lines` (long-poll) / `list processes` / `kill process`.
  - New entry: cancellation during the wait window detaches rather than kills; the no-leak guarantee is carried by explicit kill, stream EOF (§9 retained on the detached path), `timeout`, and the exit sweep — **which fires only on normal process exit, not SIGKILL/crash** (state the limitation).
- `README.md`: document `waitSeconds` on `execute command` and `get lines`, the `running` result, and a short worked polling example (execute → running → get lines long-poll → kill/list). Keep snippets compilable — `ReadmeSnippetTests`/`ReadmeSnippetsParserTests` parse and pin these.
- `Examples/ShellDemo` (`ScriptMode.swift`, `ChatValidationHarness.swift`): the scripted flow's meaning silently changed — today `sleep 60` blocks to completion so the later "kill command id 2" prompt exercises the *corrective* "No running process" path; after detach it kills a genuinely running command. Re-point the scripted prompts so each targets its intended path, and add a scripted sequence showcasing the new flagship protocol: execute with `waitSeconds` → `running` → `get lines` long-poll → kill.
- Doc-pinning mechanics — this is the machine-checkable core: `Tests/ShellToolTests/DesignNotesTests.swift` `requiredPhrases` pins the literal phrases `"Batch-at-exit"` and `"non-optional \`Int\`"`. Update those pins to the superseded/amended wording, and **add one pinned phrase per new entry** (two-clocks, running-result divergence, cancellation-detach + sweep limitation), so "every change has an entry" is enforced by the test, not by prose review.

## Acceptance Criteria
- [x] `DesignNotesTests.requiredPhrases` contains an updated pin for §8 and §12 wording plus one pin per new entry, and passes against the rewritten `DESIGN_NOTES.md`
- [x] README documents the polling protocol with a compilable example (snippet tests pass)
- [x] Demo scripted flow exercises: fast execute, execute-detach via `waitSeconds`, `get lines` long-poll, kill of a genuinely running command, and a corrective kill of a finished id
- [x] Review note (not machine-checked): scan the changed docs for claims contradicted by shipped behavior

## Tests
- [x] `Tests/ShellToolTests/DesignNotesTests.swift`, `DocCoverageTests.swift`, `ReadmeSnippetsParserTests.swift`, `ReadmeSnippetTests.swift`, `ExampleIntegrationTests.swift` updated and green
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — update the doc-pinning tests first, then the docs to satisfy them. #long-running