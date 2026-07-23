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

## Departures discovered during implementation

The §8 entries above were decided during planning. The five below were found by a
plan-deviation audit *after* implementation — shipped behaviors that depart from
the plan (§3/§4/§8) or from the Rust tool but were not recorded when they were
made. They are captured here so the plan's "deliberate departures are few and
recorded" principle holds for the shipped code, not just the design.

### 8. Batch-at-exit log append (superseded)

**Superseded** by incremental recording (kanban task `01KY57R5GC12AQJ439NS9RENTY`
/ `s9renty`): `ShellRunner` now streams each chunk's newly completed lines into
`ShellState.appendLines` as they arrive — via a single consumer task that drains
one shared `AsyncStream` funnel fed by the two stream readers, so extraction and
the flush call are never split across concurrent callers (see the file header of
`Sources/ShellTool/ShellRunner.swift`) — rather than batching everything into one
`appendLines` call at exit. This closes the gap this entry originally described:
a command killed *mid-stream* now reports whatever lines had already streamed in
before the kill, not always `0` (`KillResult.linesCaptured`,
`Sources/ShellTool/Operations/KillProcess.swift`). The original entry is kept
below for history.

`ShellRunner` used to collect a command's output in an `OutputCollector` and call
`ShellState.appendLines` **once**, after both the stdout and stderr streams had
closed (the `collector.finish()` → `appendLines` sequence in
`Sources/ShellTool/ShellRunner.swift`), rather than streaming each line into the
log incrementally as the plan's "stream stdout+stderr into the log" wording and
the Rust guard do. Batching at exit kept the shared per-command line counter
free of a concurrent-write race between the two stream readers, at the cost of
one property: a command killed *mid-stream* had recorded no lines yet, so
`KillResult.linesCaptured` was `0`.

### 9. Post-stream group-kill / timeout races stream EOF

`ShellRunner.run` races the optional timeout timer against *stream EOF* — the
body's task group finishes as soon as both the stdout and stderr readers reach
end of stream — and an unconditional `defer { _ = killpg(pid, SIGKILL) }` fires the
moment the body exits. The plan (and the Rust guard) instead wait on the *child
process itself*. The observable difference: a command that closes or redirects
its own stdout and stderr but keeps running (e.g. `exec >/dev/null 2>&1; sleep
100`) reaches stream EOF immediately, so the body exits, the `defer` SIGKILLs the
group, and the command is reported `completed` with exit `-1` — **not**
`timed_out`. The rationale is deliberate: the unconditional group-kill guarantees
no backgrounded grandchild leaks as a daemon, and swift-subprocess's own child
reap cannot complete until the pipes are closed, so the runner must close them by
killing the group on every exit path. See `run(_:)` in
`Sources/ShellTool/ShellRunner.swift`.

### 10. Audit logging not ported

The Rust `builtin/shell/config.yaml` carries an `enable_audit_logging` setting. It
is removed here as dead code — nothing in this port consumes it — and the line is
stripped from the embedded builtin YAML in `Sources/ShellTool/ShellPolicy.swift`.
As a result the embedded builtin config is **no longer byte-identical** to sah's
`builtin/shell/config.yaml`: it drops the `enable_audit_logging` line (and, per §4
above, `max_line_length`). This narrows the plan §5.6 "security layer ported
whole" claim — the deny/permit list and the enforced scalar limits are ported
faithfully, but the builtin config file is a faithful *subset*, not a
byte-for-byte copy.

### 11. Public API is `ShellTool.make(preferredDirectory:)`, not `ShellContext(state:policy:)`

Plan §4 sketched an embedder constructing a `ShellContext(state:policy:)`
directly. As shipped, `ShellContext` and `ShellState` are module-internal and
cannot be built from outside the module, so that snippet cannot compile for an
embedder. The public surface is instead the factory
`ShellTool.make(preferredDirectory:)` in `Sources/ShellTool/ShellTool.swift`,
which assembles the internal context itself — the one `preferredDirectory`
parameter lets a caller point the `.shell` store somewhere other than the working
directory. `make(context:)` remains available for `@testable` callers.

### 12. `ExecuteResult.exitCode` is non-optional `Int`

Plan §3 spelled the exit code as `Int?`. The shipped `ExecuteResult.exitCode` in
`Sources/ShellTool/Operations/ExecuteCommand.swift` is a non-optional `Int`: a
*killed* record has a stored exit code of `nil` (`ShellState.killProcess` →
`completeCommand(exitCode: nil)`), which the result assembly backfills to `-1`
via `record?.exitCode ?? outcome.exitCode`; a *timed-out* record already stores
`-1` directly (the runner's timeout path calls `completeIfRunning(exitCode:
-1)`). Either way the model always sees a concrete integer, with `-1` as the
sentinel for "died by signal or timeout" — matching the Rust tool's own
exit-code convention.

## Further reading

- [`README.md`](README.md) — declaring an operation, fusing the tool, registering it on a
  session, and the dual-use CLI.
- The sibling [`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
  `DESIGN_NOTES.md` — where the fusion machinery this package builds on departed from *its*
  plan and from the Rust operation-tool pattern.
