---
depends_on:
- 01KWYJ9XPG0K9VNSXCM66H3H2K
- 01KWYJA9J0KQVDSQMHHB8R4RT6
- 01KWYJAHWJ7WSF7RYGNCXYD60P
position_column: todo
position_ordinal: 8b80
title: Fuse into ShellTool.make()
---
## What
In `Sources/ShellTool/ShellTool.swift`, fuse the five operations (`ExecuteCommand`, `ListProcesses`, `KillProcess`, `GrepHistory`, `GetLines`) into a single `OperationTool<ShellContext>` via `ShellTool.make(context:)`:

- Tool name `"shell"`, description matching sah: *"Virtual shell with history and process management. Execute commands, grep output history, and manage running processes."*
- Wire the missing-`op` → `execute command` default using the resolver's opt-in `inferOp` closure (`OperationResolver.InferenceHook`) — the Rust tool's empty-op default, expressed via upstream's inference hook rather than hand-rolled.
- Confirm the fused schema is a flat union: required `op` enum + all fields optional, per-op requiredness validated at dispatch (already exercised per-op in the three preceding tasks; this task verifies it holds across the *fused* schema, not just each op in isolation).
- Rely on the upstream resolver's snake_case/camelCase normalization for cross-op payload parity — no hand-rolled key normalization here.

## Acceptance Criteria
- [ ] All five ops dispatch correctly through the single fused `shell` tool by their exact sah op strings
- [ ] A payload with no `op` field defaults to `execute command` when run through the fused tool
- [ ] `ShellTool.make(context:)` returns a working `OperationTool<ShellContext>` usable directly in a `LanguageModelSession(tools:)` list
- [ ] The fused tool's rendered schema exposes exactly the five op strings and their per-op parameters (spot-checked via `tokenCount(for:)` or schema introspection)

## Tests
- [ ] `Tests/ShellToolTests/FusionTests.swift`: one dispatch test per op through the *fused* `ShellTool`, distinct from the per-op tests in the three preceding tasks (this exercises fusion, not the op logic itself)
- [ ] Missing-op-defaults-to-execute-command test at the fused-tool level
- [ ] `ShellTool.make()` construction test asserting the returned tool's name is `"shell"`

## Workflow
- Use `/tdd` — write the fused-dispatch tests first; the underlying op logic is already tested and GREEN from the prerequisite tasks, so this task is purely about correct fusion wiring.