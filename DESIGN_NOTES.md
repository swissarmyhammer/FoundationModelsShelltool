# Design notes

This document records where the shipped `FoundationModelsShelltool` departs from a stated
design — either from the Rust [`swissarmyhammer`](https://github.com/swissarmyhammer/swissarmyhammer)
shell tool this package ports, or from this project's own plan as written before
implementation began — and why. The plan is the design record of record; this document is
the changelog against it, matching the sibling
[`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)'s
`DESIGN_NOTES.md` convention.

## Departures from the Rust shell design (plan §8)

The plan's §8 names seven deliberate departures from the Rust pattern, decided during
planning from primary-source research. Each is summarized here.

### 1. Typed JSON outputs instead of preformatted text blocks

The Rust ops emit preformatted human-readable text (a rendered process table, a
`"{line}: {text}"` block). This port returns small `Encodable` result types instead —
`ExecuteResult`, `ProcessRow`/`ListProcessesResult`, `KillResult`, `GrepMatches`,
`LineRange` — which the fused `OperationTool` JSON-encodes into its `String` output. A typed
object is what a model consumes most reliably, and it avoids the double-escaping a
preformatted text block would incur when wrapped in the tool's JSON envelope. `list
processes` in particular returns a top-level JSON *array* of record rows rather than a
wrapped object (see `ListProcessesResult`'s `singleValueContainer` encoding). See the result
types in `Sources/ShellTool/Operations/`.

### 2. No tolerant string-to-int parsing

The Rust tool tolerantly parses numeric arguments that may arrive as strings. Here that
machinery is unnecessary on both surfaces: FoundationModels guided generation constrains the
model to the declared schema types (an `Int?` parameter is generated as a number), and the
CLI's `@Operation`-generated `ParsableCommand` leaf parses `Int` options through
swift-argument-parser's own typed decoding. So `timeout`, `id`, `commandID`, `start`, `end`,
and `limit` are plain `Int`/`Int?` properties with no string fallback — the type system and
guided generation do the coercion the Rust code did by hand.

### 3. `grep history` `limit` defaults to 10

`GrepHistory.limit` (and the underlying `ShellState.grep`) default to **10**, and the
parameter is documented as 10. The Rust tool's doc string still advertises a stale `50`; that
value is deliberately not carried over — the shipped default and its documentation agree on
10. `total` always reports every match regardless of `limit`, so a model that sees
`total > shown` knows to raise `limit`. See `ShellState.grep` and `GrepHistory`.

### 4. `max_line_length` (2000) not ported

The Rust config carries a `max_line_length` setting (default 2000) that, in practice, is
never enforced in the Rust code path — it is dead configuration. Rather than port an
unenforced knob, this project drops it entirely. `ShellSettings` carries only the settings
that actually gate a command: `max_command_length`, `max_env_value_length`, and
`enable_validation`. See `Sources/ShellTool/ShellPolicy.swift`.

### 5. UUID session ids (Rust uses ULID)

Each `ShellState` mints a fresh session id at construction to namespace its lines in the
shared `.shell/log` (`{sessionID}:{cmdID}:{lineNumber}:{text}`). Rust uses a ULID; this port
uses a `UUID`. The id is only ever used as an opaque log-namespace prefix — no code relies on
the lexicographic time-ordering property a ULID would provide — so a `UUID` (available in
Foundation with no extra dependency) is the simpler choice. See `ShellState.sessionID` in
`Sources/ShellTool/ShellState.swift`.

### 6. macOS-only (no Windows/other arms)

The Rust tool has platform-specific arms (including Windows). This port is macOS-only, and
the platform is fixed by the stack anyway: it depends on FoundationModels (Apple platforms)
and spawns children via `Subprocess`/`posix_spawn` running `/bin/sh -c`. The process-group
teardown (`killpg`, `POSIX_SPAWN_SETPGROUP`) is POSIX. `Package.swift` declares only
`.macOS(.v26)`, and there are no `#if os(...)` platform branches to maintain.

### 7. Free upgrades from the `OperationTool` machinery, absent in Rust `shell`

Fusing the operations through `FoundationModelsOperationTool` brings behaviors the Rust
`shell` tool does not have, for free:

- **Op and verb aliases** and **`"noun verb"` reordering** — the resolver accepts
  `command execute` as well as `execute command`, plus registered verb aliases.
- **Key-case normalization** — payload keys are matched ignoring case and `_`/`-`
  separators, so `command_id`, `commandId`, and `command-id` all resolve to the same
  parameter.
- **Corrective-message retry cap** — a bounded number of corrective retries within a turn
  stops the model looping forever on a repeatedly-rejected call (e.g. a policy-denied
  command), instead of either aborting or spinning.
- **`includesSchemaInInstructions`** — control over whether the fused schema is injected
  into the prompt, so a caller can trade prompt-context cost against out-of-band schema
  delivery.

These come from `OperationTool`/`OperationResolver`/`SchemaFusion`; `ShellTool.make` only has
to fuse the five operations and supply the `inferOp` hook for the empty-op default (the Rust
dispatch's `"execute command" | "" =>`). See `Sources/ShellTool/ShellTool.swift` and the
sibling package's `DESIGN_NOTES.md` for the fusion machinery's own design rationale.

## Further reading

- [`README.md`](README.md) — declaring an operation, fusing the tool, registering it on a
  session, and the dual-use CLI.
- The sibling [`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
  `DESIGN_NOTES.md` — where the fusion machinery this package builds on departed from *its*
  plan and from the Rust operation-tool pattern.
