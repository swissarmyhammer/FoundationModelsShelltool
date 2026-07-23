---
assignees:
- claude-code
depends_on:
- 01KY57S9Y3QJF0NN668YDR8Y7K
- 01KY57SQEF3368T4GK7T3ZF09S
position_column: todo
position_ordinal: '8480'
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
- [ ] `DesignNotesTests.requiredPhrases` contains an updated pin for §8 and §12 wording plus one pin per new entry, and passes against the rewritten `DESIGN_NOTES.md`
- [ ] README documents the polling protocol with a compilable example (snippet tests pass)
- [ ] Demo scripted flow exercises: fast execute, execute-detach via `waitSeconds`, `get lines` long-poll, kill of a genuinely running command, and a corrective kill of a finished id
- [ ] Review note (not machine-checked): scan the changed docs for claims contradicted by shipped behavior

## Tests
- [ ] `Tests/ShellToolTests/DesignNotesTests.swift`, `DocCoverageTests.swift`, `ReadmeSnippetsParserTests.swift`, `ReadmeSnippetTests.swift`, `ExampleIntegrationTests.swift` updated and green
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — update the doc-pinning tests first, then the docs to satisfy them. #long-running