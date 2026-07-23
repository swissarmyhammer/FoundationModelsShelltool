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
- actor: claude-code
  id: 01ky89p3abx9trt3wy8ka99aha
  text: |-
    Picked up from review with a fresh "Review Findings (2026-07-23 14:08)" checklist of 11 doc-comment findings (all same category: `///` first line must be a complete, period-terminated sentence). Moved review → doing per /implement.

    Fixed all 11 cited findings by rewriting each flagged doc comment's first line into a complete sentence ending in a period (10 in ChatValidationHarness.swift, 1 in DesignNotesTests.swift), generally by splitting a long run-on first line into a short complete-sentence summary plus a second paragraph carrying the remaining detail — matches the file's existing multi-paragraph doc-comment style.

    Root-cause sweep (per the task instructions, not just the 11 cited lines) found 3 additional undetected occurrences of the same defect in ChatValidationHarness.swift and fixed them too:
    - `deniedCommandPrompt`'s doc comment ended with "and"
    - `availabilityReasonMessages`'s doc comment's first line cut off mid type-reference with no punctuation
    - `evaluateScriptedPrompt`'s doc comment ended with "tool"

    Also caught and corrected one self-introduced regression mid-pass: an early edit to `deniedCommandPrompt`'s doc appended a second paragraph but left the original incomplete first line untouched — re-edited to actually complete the first-line sentence before moving on.

    Verified line-by-line by reading the full file after all edits: every `///` doc comment in both files now has a first line that is a complete, period-terminated sentence.

    `swift test` reconfirmed fully green: 201 tests, 17 suites, 0 failures (matches baseline). Also ran `swift test --filter DesignNotesTests` in isolation to confirm the 8 pinned phrase cases still pass.

    Updated all 11 Review Findings checklist items to `- [x]` via `update task` with real embedded newlines (not literal `\n`), and re-fetched to confirm the description renders correctly and `tags`/`filter_tags` still include `long-running`. Progress now 1.0.

    Leaving task in `doing` per /implement's contract — not moving to `review` myself.
  timestamp: 2026-07-23T20:11:48.427640+00:00
- actor: claude-code
  id: 01ky8f7f5d1xtr851zqyb94keb
  text: |-
    Round 3 complete. Moved review → doing, worked every unchecked item in the 2026-07-23 15:13 checklist plus did a full top-to-bottom re-read of both files rather than only the 17 cited lines.

    Changes in ChatValidationHarness.swift: fixed 14 cited doc-comment first-line violations (noun phrases missing a verb; first lines that trailed off across multiple physical lines) plus 3 more found during the sweep (unknownAvailabilityReasonText, skipValidationMessage, noOpText — all fragments). Extracted findMatchingCallOp(calls:toolName:) out of lastToolCallOp()'s inner loop per the structural finding; had to type the parameter as Transcript.ToolCalls (not [Transcript.ToolCall] as literally suggested) since that's the actual element type Transcript yields — the array signature failed to compile.

    Changes in DesignNotesTests.swift: fixed the 3 cited items (struct-doc first line, the "Entries 8 and 12..." paragraph, designNotes()'s doc) plus the requiredPhrases doc (fragment, no verb) found during the sweep.

    Self-check: grepped both files for /// afterward and read every line back — confirmed every doc comment's first physical line is now a complete, verb-bearing, period-terminated sentence.

    A follow-up review pass caught 3 more items on my own changes: added missing - Returns:/- Throws: sections to lastToolCallOp, findMatchingCallOp, and designNotes() (matching the file's existing convention); left a pre-existing, unrelated retry-cap magic-number duplication in probeRetryCapBehavior as-is with logged justification (out of scope for this doc-comment/nested-loop task).

    swift build and swift test both fully green: 201 tests, 17 suites, 0 failures — unchanged from baseline, confirming the nested-loop refactor preserved behavior. Diagnostics check (mcp__sah__diagnostics check working) reported 0 errors, 0 warnings.

    Leaving task in doing per /implement's contract — not moving to review myself.
  timestamp: 2026-07-23T21:48:40.493429+00:00
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

## Review Findings (2026-07-23 14:08)

- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:18` — The first line of a doc comment must be a single-sentence summary ending in a period. This first line ends with 'in' and leaves the sentence incomplete, forcing the reader to continue to the next line. Rewrite to complete the summary on the first line: `/// A scripted prompt paired with the op the shell tool should dispatch.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:29` — The first line of a doc comment must end in a period. This summary spans multiple lines because the first line ends abruptly with 'a long'. Rephrase to fit a complete thought on the first line: `/// The scripted prompt set in execution order, covering long commands, truncation follow-ups, corrective kills, and soft-deadline detach flows.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:62` — The first line of a doc comment must end in a period. This line ends with 'in', leaving the thought incomplete. Complete the first line: `/// The fallback text used for unavailability reasons not in availabilityReasonMessages.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:65` — The first line of a doc comment must end in a period. This line ends with 'no', leaving the summary incomplete. Complete the sentence: `/// The placeholder string shown when a response produced no tool call.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:75` — The first line of a doc comment must end in a period. This line ends with 'on', leaving the summary incomplete. Complete the first line: `/// Runs the live-model validation if SystemLanguageModel is available on this device; otherwise prints a skip message.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:96` — The first line of a doc comment must end in a period. This line ends with 'is', leaving the summary incomplete. Complete the first line: `/// The shared suffix of the skip messages that run() prints when the model is unavailable, so phrasing lives in one place.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:100` — The first line of a doc comment must end in a period. This line ends with 'plan's', leaving the summary incomplete. Complete the summary: `/// Prints the fused tool's rendered schema token count so the schema-in-prompt cost is observable.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:118` — The first line of a doc comment must end in a period. This line ends with 'many', leaving the summary incomplete. Complete the first line: `/// Sends every scripted prompt to the session and tallies how many dispatched their expected operations.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:149` — The first line of a doc comment must end in a period. This line ends with 'row,' (a comma), leaving the summary incomplete. Complete the first line: `/// Sends a policy-denied command up to three times to observe corrective recovery and retry-cap behavior.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:165` — The first line of a doc comment must end in a period. This line ends with 'in', leaving the summary incomplete. Complete the first line: `/// The op argument of the most recent tool call matching the given tool name, or nil if none.`.
- [x] `Tests/ShellToolTests/DesignNotesTests.swift:12` — The first line of a doc comment must end in a period. This line ends without punctuation. Rewrite as a complete first sentence: `/// Verifies that the eight "departures discovered during implementation" entries (8–15) are present in DESIGN_NOTES.md.`.

**Doc-claim verification (manual, per acceptance criterion):** Cross-checked README.md/DESIGN_NOTES.md prose against Sources/ShellTool/ — `defaultWaitSeconds = 30` matches the "default 30" / "defaults to 30s" claims; `ExecuteResult.exitCode: Int?` is `nil` in `runningResult(commandID:in:)`, matching the "omitted, not null" claim; the README worked-example `outputNote` string matches `ExecuteCommand.runningOutputNote` verbatim; `GetLines`'s long-poll re-check loop matches the README's cadence description; `ProcessRegistry`'s `atexit` sweep doc comment independently states the same "normal exit only, not SIGKILL/crash" limitation DESIGN_NOTES §15 claims. No contradictions found.

**Fix pass (2026-07-23):** All 11 findings fixed by rewording each flagged `///` doc comment's first line into a complete sentence ending in a period (content preserved; wording adjusted, often by splitting into a short first-line summary plus a second paragraph for the remaining detail). Root-cause sweep of both files for the same defect beyond the 11 cited lines found and fixed 3 additional occurrences: `deniedCommandPrompt`'s doc comment (ended with "and"), `availabilityReasonMessages`'s doc comment (first line cut off mid-clause with no punctuation), and `evaluateScriptedPrompt`'s doc comment (ended with "tool"); plus `requiredPhrases`' doc comment in DesignNotesTests.swift (ended with "appear", no period). `swift test` reconfirmed fully green: 201 tests, 17 suites, 0 failures.

## Review Findings (2026-07-23 15:13)

- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:35` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence, e.g. `/// Represents a scripted prompt paired with the op the shell tool should dispatch.` or `/// A test prompt that pairs with its expected operation.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:37` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence, e.g. `/// The natural-language prompt to send to the model.` or `/// Stores the natural-language prompt sent to the model.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:39` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence, e.g. `/// The expected `"verb noun"` operation string for the model to dispatch.` or `/// The operation code the model is expected to dispatch.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:70` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence with a main verb, e.g. `/// Represents a command that `ShellPolicy` denies, used for observing corrective recovery.` or `/// A policy-denied command used to probe corrective recovery behavior.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:75` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence, e.g. `/// Specifies the instructions that the harness's `LanguageModelSession` runs under.` or `/// The system instructions provided to the validation session.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:79` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues across multiple lines. Rewrite the first line as a complete sentence that stands alone, e.g. `/// Maps unavailability reasons to human-readable text.` then place the detailed explanation in a following paragraph.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:92` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 93. Rewrite as a complete first-line summary, e.g. `/// The skip message shown when Foundation Models is unavailable.` then elaborate in a following paragraph.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:100` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 101. Rewrite as a complete first-line summary, e.g. `/// Runs the live-model validation if the device supports Foundation Models, or prints a skip message.` then add details in a following paragraph if needed.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:125` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 126. Rewrite as a complete first-line summary, e.g. `/// Reports the token count of the fused tool's rendered schema.` then explain why in a following paragraph.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:137` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 138. Rewrite as a complete first-line summary, e.g. `/// Measures how many scripted prompts dispatch their expected operations.` then provide parameter and return details after a blank line.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:156` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 157. Rewrite as a complete first-line summary, e.g. `/// Evaluates a scripted prompt and returns whether its tool call matched the expected operation.` then add parameter and return details.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:180` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 181. Rewrite as a complete first-line summary, e.g. `/// Probes retry-cap behavior by repeatedly sending a policy-denied command.` then explain the scenario in a following paragraph.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:195` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 196. Rewrite as a complete first-line summary, e.g. `/// Returns the op of the most recent tool call matching the given tool name, or nil if none.`.
- [x] `Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift:228` — Nested loops: `lastToolCallOp()` contains a for loop over transcript entries with an inner for loop over calls, increasing cognitive complexity and readability difficulty. Extract the inner loop into a separate helper function to reduce nesting: `private static func findMatchingCallOp(calls: [Transcript.ToolCall], toolName: String) -> String?` and call it from the outer loop.
- [x] `Tests/ShellToolTests/DesignNotesTests.swift:3` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 4. Rewrite as a complete first-line summary, e.g. `/// Verifies that all eight departure entries (8–15) are present in DESIGN_NOTES.md.` then add rationale in a following paragraph.
- [x] `Tests/ShellToolTests/DesignNotesTests.swift:17` — First line of doc comment must be a complete sentence ending in a period; this line is incomplete and continues to line 18. Rewrite as a complete first-line summary, e.g. `/// Documents that entries 8 and 12 were superseded by the soft-deadline detach work.` then explain the details in a following paragraph.
- [x] `Tests/ShellToolTests/DesignNotesTests.swift:43` — First line of doc comment ends in a period but is not a complete sentence; it is a noun phrase missing a main verb. Rewrite as a complete sentence, e.g. `/// Returns the contents of the package root's `DESIGN_NOTES.md`.` or `/// Reads the package root's `DESIGN_NOTES.md` and returns its contents.`.

**Fix pass (2026-07-23, round 3):** Read every `///` doc comment top to bottom in both files (not just the 17 cited lines) and fixed every first-line violation found: noun phrases with no main verb, and first lines that trailed off (no period) requiring a following physical line to complete the thought. Beyond the 17 cited items, also fixed: `unknownAvailabilityReasonText`'s doc (fragment, no verb), `skipValidationMessage`'s doc (fragment, no verb, trailed off), and `noOpText`'s doc (fragment, no verb) in ChatValidationHarness.swift. Every first physical line is now a complete, verb-bearing, period-terminated sentence on its own line; longer explanations moved to a following paragraph after a blank `///` where needed. Fixed the structural finding by extracting `findMatchingCallOp(calls:toolName:)` out of `lastToolCallOp()`'s inner loop (signature uses `Transcript.ToolCalls`, the actual type of transcript tool-call collections, not `[Transcript.ToolCall]` as literally suggested — using the suggested array type failed to compile). Self-check: grepped both files for `///` afterward and read every line back to confirm each first line is a complete sentence.

A follow-up `review working` pass (independent of this task's cited findings) flagged two functions I touched (`lastToolCallOp`/`findMatchingCallOp` in ChatValidationHarness.swift, `designNotes()` in DesignNotesTests.swift) for missing formal `- Returns:`/`- Throws:` doc sections given their non-Void/throwing signatures — fixed by adding those sections, matching the convention already used elsewhere in the same file (e.g. `evaluateScriptedPrompt`, `measureOpCallAccuracy`). A third finding from that same pass (retry-cap literal `3` duplicated between the message string and the loop range in `probeRetryCapBehavior`, pre-existing code untouched structurally by this task) was left as-is with this logged justification: it is unrelated to the doc-comment/nested-loop scope of this task, and `/implement`'s "no unrelated refactors" rule applies.

`swift build` and `swift test` reconfirmed fully green: 201 tests, 17 suites, 0 failures, exit code 0.