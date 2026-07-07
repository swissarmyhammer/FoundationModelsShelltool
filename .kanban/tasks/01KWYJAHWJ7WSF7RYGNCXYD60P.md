---
depends_on:
- 01KWYJ9XPG0K9VNSXCM66H3H2K
position_column: todo
position_ordinal: 8a80
title: GrepHistory + GetLines ops
---
## What
Implement two `@Generable @Operation` structs in `Sources/ShellTool/Operations/`, using the `ShellContext` defined in the "ExecuteCommand op + ShellContext" task:

- `GrepHistory` (op `"grep history"`): `pattern` (required), `literal?` (default `false`), `commandId?`, `limit?` (default `10`, documented as `10` — plan §8.3 departure from Rust's stale "50" doc string). Delegates to `ShellState.grep`. Returns `GrepMatches` (matches + `shown`/`total`). Invalid regex → corrective message, not a thrown error.
- `GetLines` (op `"get lines"`): `commandId` (required), `start?` (default 1), `end?` (default last line). Delegates to `ShellState.getLines`. Returns `LineRange` (commandId, first, last, numbered lines). Unknown `commandId` → empty result (parity with Rust, not an error).

## Acceptance Criteria
- [ ] `grep history` dispatches through `AnyOperation`, respects `limit` (default 10), and reports `total` separately from `shown`
- [ ] `grep history` with `literal: true` matches escaped exact text, not regex syntax
- [ ] `grep history` with an invalid regex pattern produces a corrective message
- [ ] Missing required `pattern`/`commandId` params produce corrective messages
- [ ] `get lines` on an unknown `commandId` returns an empty result, not an error
- [ ] `get lines` default `start`/`end` cover the full stored range when omitted
- [ ] `GrepMatches` and `LineRange` JSON shapes match the field names above

## Tests
- [ ] `Tests/ShellToolTests/HistoryOpsTests.swift`: `grep history` dispatch test with limit/total split
- [ ] `literal: true` exact-match test
- [ ] Invalid-regex corrective-message test
- [ ] Missing-required-param corrective-message tests (both ops)
- [ ] `get lines` unknown-id-empty-result test
- [ ] `get lines` default-range test
- [ ] JSON-shape snapshot tests for `GrepMatches` and `LineRange`

## Workflow
- Use `/tdd` — write the limit/total and invalid-regex tests first, then wire the ops to `ShellState.grep`/`getLines`.