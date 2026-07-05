# Plan: FoundationModelsShelltool — the sah `shell` tool for Foundation Models

A Swift package that ports the swissarmyhammer **`shell` MCP tool** — a virtual command
shell with persistent output history and process management — to Apple's
[Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/),
built on
[`FoundationModelsOperations`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
(the sah "operation" pattern: `op: "verb noun"` dispatch, flat-union fused schema,
forgiving resolver, dual-use CLI). One fused `OperationTool` named **`shell`** carries the
same five operations as the Rust original: **`execute command` / `list processes` /
`kill process` / `grep history` / `get lines`**. **Target: macOS, on-device.**

---

## 1. Guiding principles

- **Same vocabulary as sah.** The op strings, parameter names, defaults, and storage
  layout (`.shell/log`, `.shell/.gitignore`, `.shell/config.yaml`) match the Rust tool
  (`swissarmyhammer-tools`, `mcp/tools/shell/`) so a user moving between the Rust MCP
  server and this package sees one tool, not two dialects. Deliberate departures are
  few and recorded (§8).
- **Every command's output is history.** The core idea of the sah shell: output is
  never lost to truncation. `execute command` shows a 32-line tail; the full output
  lands in an append-only log addressable by `command_id` + line number, retrievable
  with `get lines` and searchable with `grep history`. This is what makes the tool
  better than a bare exec for a context-constrained on-device model.
- **Operations are declarations.** The five ops are `@Generable @Operation` structs on
  a shared `ShellContext`; we inherit schema fusion, the forgiving resolver,
  return-don't-throw corrective errors, the retry cap, and the CLI driver from
  `FoundationModelsOperations` — nothing op-shaped is hand-rolled here.
- **State is brief, execution is long.** `ShellState` is an actor touched only for
  bookkeeping (assign id, append lines, complete, kill). A running command never holds
  the actor, so `list processes` and `kill process` work *while* another `execute
  command` is mid-flight — the property that makes `kill process` useful at all.
- **macOS only.** `Process`/posix_spawn and `/bin/sh` don't exist on iOS; unlike the
  sibling packages there is no graceful iOS stub — the package declares macOS 26+ and
  nothing else.

## 2. Background: the Rust tool being ported

Reference implementation: `../swissarmyhammer` crate `swissarmyhammer-tools`, module
`mcp/tools/shell/` (op structs + dispatch), with `swissarmyhammer-shell` (security
config), `swissarmyhammer-operations` (the pattern `FoundationModelsOperations` already
ports), and `apps/shelltool-cli` (the CLI). Registered as tool name `"shell"`, category
`Replacement { native: "Bash" }`. Load-bearing behaviors to carry over:

- **Dispatch**: `op` string selects the operation; empty/missing `op` defaults to
  `execute command`; unknown op → error listing all five.
- **History**: singleton state per process; fresh session id per process; commands get
  monotonic 1-based ids (`commands.len() + 1`); every stdout line then every stderr
  line is appended to a single flat log file as
  `{session_id}:{cmd_id}:{line_number}:{text}\n` with a per-command 1-based line
  counter continuing from stdout into stderr. No rotation, no eviction — the log grows
  for the process lifetime; "truncation" in responses is display-only.
- **Storage dir**: prefer `<cwd>/.shell`; if uncreatable (read-only cwd), fall back to
  `<tmp>/.shell-{unique}`. Writes `.gitignore` (`*` + `!.gitignore`) if absent; log
  file is `.shell/log`, append mode.
- **Execution**: each command is an independent `sh -c {command}` child — no shared
  cwd/env between commands; stdin is null; stdout/stderr piped and read line-by-line
  concurrently; working directory = request's or the session root; env vars are
  *added on top of* the inherited environment.
- **Limits**: 10 MiB output cap enforced at capture, truncated at a line boundary with
  marker `[Output truncated - exceeded size limit]`; binary detection = null byte in
  the first 8 KiB → `[Binary content: {n} bytes]`; command length ≤ 256 KiB; env value
  ≤ 1024 chars.
- **Timeout**: only if requested (no default) — on elapse, SIGKILL the child's
  **process group**, status `timed_out`, exit code −1.
- **Kill**: `kill process` SIGKILLs the process group by stored PID; only running
  commands are in the PID map.
- **Exit codes are data**: a non-zero exit is a *successful* tool call reporting
  `exit_code: 2` — only spawn/system failures are tool errors.
- **Security**: permit-then-deny regex policy from a three-layer stacked YAML config
  (builtin embedded → `~/.shell/config.yaml` → `{git_root}/.shell/config.yaml`),
  reloaded fresh on every call; builtin denies are catastrophic-mistake guards
  (`rm -rf /`, `dd ... of=/dev/`, `sudo`, `curl | sh`, …), explicitly *not* a security
  boundary; shell metacharacters allowed. Env var names must match
  `^[A-Za-z_][A-Za-z0-9_]*$`, values checked for length/null/newline; working
  directory rejects `../` traversal.
- **Grep**: regex (or `literal: true` for escaped exact text) over the log, optional
  `command_id` filter, capped results with a "Showing {shown} of {total}" trailer.

Two known wrinkles in the original, resolved here in §8: the grep `limit` doc/code
mismatch (doc says 50, code defaults 10) and the declared-but-unenforced
`max_line_length: 2000`.

## 3. Architecture

### Package layout

Swift package `FoundationModelsShelltool`, Swift 6.2 tools, platform **macOS 26+**
(FoundationModels availability; no iOS). Mirrors upstream's root-package layout —
Examples are targets of the root `Package.swift`, so one `swift build` covers
everything (the Skills/Agents convention):

```
Sources/
  ShellTool/               # ops, ShellContext, ShellState actor, ShellRunner,
                           #   OutputBuffer, ShellPolicy (security), output types
Examples/
  ShellDemo/
    Sources/shell-demo/    # thin executable: CLI / --chat / --script modes
Tests/
  ShellToolTests/          # state, runner, policy, dispatch, CLI round-trip tests
```

Dependencies:
- `FoundationModelsOperations` (branch `main`) — `Operations` + `OperationsCLI`
  products; re-exports ArgumentParser.
- `apple/swift-subprocess` — spawning with process-group control and async
  line-streamed stdout/stderr (see Process runner; hand-rolled posix_spawn is the
  recorded fallback, §7.2).
- `jpsim/Yams` — the stacked `.shell/config.yaml` security config.

### The operation vocabulary

One fused `OperationTool` (name `"shell"`, description matching sah: *"Virtual shell
with history and process management. Execute commands, grep output history, and manage
running processes."*), five `@Generable @Operation` structs sharing a `ShellContext`
(the state actor + runner + policy). Flat-union schema: required `op` enum + all
fields optional, per-op requiredness validated at dispatch with corrective messages,
never throws (upstream's pattern, including the retry cap).

| op | parameters | behavior |
|---|---|---|
| `execute command` | `command` (req), `timeout?` secs, `workingDirectory?`, `environment?` (JSON-string map) | Validate against policy → spawn `sh -c` in its own process group → stream stdout+stderr into the log under a fresh `command_id` → report status, exit code, total line count, duration, and the **last-32-line tail**. No default timeout. |
| `list processes` | *(none)* | The full command history table: id, status (`running`/`completed`/`killed`/`timed_out`), exit code, line count, wall-clock start, duration, command. |
| `kill process` | `id` (req) | SIGKILL the process group of a still-running command by stored PID; marks the record `killed`, reports lines captured so far. Unknown/finished id → corrective message. |
| `grep history` | `pattern` (req), `literal?` (default false), `commandId?`, `limit?` (default 10) | Regex (or escaped-literal) search over the session's log, optionally scoped to one command; returns matches as `(commandId, line, text)` plus `total` so the model knows to raise `limit`. Invalid regex → corrective message. |
| `get lines` | `commandId` (req), `start?` (default 1), `end?` (default last) | Retrieve an exact line range of a command's stored output — the follow-up to a truncated tail or a grep hit. Unknown id → empty result (parity), not an error. |

- Field names are camelCase in Swift (`workingDirectory`, `commandId`); upstream's
  resolver normalizes snake_case payloads (`working_directory`, `command_id`) to them,
  so sah-style payloads work verbatim.
- Nouns follow sah exactly (`command`, `processes`, `process`, `history`, `lines`) —
  parity beats the singular-noun aesthetic; the forgiving resolver tolerates
  reordering, case, and separators on top.
- `environment` stays a **JSON-string** parameter (`'{"KEY":"value"}'`) as in Rust —
  `@Generable` has no dictionary type, and parity keeps the parsing + validation
  identical.

### Typed outputs (departure from Rust's plain text — §8.1)

Upstream `AnyOperation.run` JSON-encodes every `Output: Encodable`; wrapping sah's
preformatted text blocks in a JSON string would double-escape them. So each op returns
a small `Encodable` struct whose keys mirror the Rust text fields:

```swift
struct ExecuteResult: Encodable {
    let commandId: Int
    let status: String            // completed | timed_out | killed
    let exitCode: Int?
    let lines: Int                // total stored lines (stdout + stderr)
    let durationMs: Int
    let output: [String]          // tail, "{lineNumber}: {text}", ≤ 32 entries
    let outputNote: String?       // "showing last 32 of 118 lines - use get lines"
                                  //   / truncation marker / binary placeholder
}
```

`ListProcessesResult` (array of record rows), `KillResult` (id, command, lines
captured), `GrepMatches` (matches + `shown`/`total`), and `LineRange` (commandId,
first, last, numbered lines) follow the same pattern. The `"{n}: {text}"` numbered-line
string format is kept — it is compact and teaches the model the line addresses that
`get lines` takes.

### `ShellState` — the history actor

```swift
actor ShellState {
    let sessionId: String                 // UUID, fresh per process (§8.5)
    private var commands: [CommandRecord] // id, command, status, exitCode, lineCount,
                                          //   startedAt (wall + monotonic), completedAt
    private var processes: [Int: pid_t]   // running commands only
    private let logURL: URL               // .shell/log, append-only
}
```

- Construction resolves the storage dir (`<cwd>/.shell`, else
  `<tmp>/.shell-{sessionId}`), writes `.gitignore` if absent, opens/creates `log`.
- `startCommand`, `registerProcess`, `appendLines`, `completeCommand`,
  `killProcess`, `listCommands` are all O(small) — no I/O-bound work other than
  appending, and never a `wait` — so the actor stays responsive while commands run.
- `getLines` / `grep` open and scan the log, filtering by the
  `{sessionId}:{cmdId}:` prefix — **history is per-session** (per process), exactly
  like Rust. Grep uses Swift `Regex` (line-anchored, `literal` pre-escaped via
  `NSRegularExpression.escapedPattern`); scanning is line-by-line so binary garbage in
  one command's output can't break another's search.

### Process runner

`ShellRunner` executes one command via **swift-subprocess**:

- `/bin/sh -c {command}` — plain `sh`, not the login shell (parity); stdin discarded;
  stdout/stderr piped.
- **Own process group** (`platformOptions` pgid = child), so timeout and
  `kill process` can `killpg(pid, SIGKILL)` and take down grandchildren — the Rust
  guard's semantics. This is the riskiest integration point (§7.2) and gets a
  dedicated test (a `sh -c 'sleep 100 & sleep 100'` tree must die entirely).
- Both streams are consumed concurrently line-by-line into an `OutputBuffer`:
  10 MiB cap with line-boundary (UTF-8-safe) truncation + marker, null-byte-in-first-
  8 KiB binary detection, UTF-8-lossy decoding, no ANSI stripping (parity — stored
  raw). stdout lines append to the log first, then stderr, one continuing counter.
- **Timeout** by racing the child's completion against `Task.sleep`; on elapse,
  SIGKILL the group, reap, record `timed_out` / exit −1. RAII parity: the runner
  guarantees group-kill + reap on *any* exit path (cancellation included) via
  `withTaskCancellationHandler` + a defer'd teardown.
- Exit code from the child's termination status; signal death reported as −1
  (parity with Rust's `code().unwrap_or(-1)`).

### Security policy

`ShellPolicy`, a direct port of `swissarmyhammer-shell`:

- **Stacked YAML config** (Yams): builtin (embedded string — the same pattern list as
  sah's `builtin/shell/config.yaml`) → `~/.shell/config.yaml` →
  `{git_root}/.shell/config.yaml`. Settings: later layer wins; deny/permit pattern
  lists: concatenated. Loaded **fresh on every `execute command`** — config edits take
  effect immediately, no cache (parity).
- **Permit-then-deny**: permit match → allow (short-circuit); deny match → corrective
  message carrying the human-readable reason; no match → allow. `enable_validation:
  false` disables command checks.
- Command length ≤ 256 KiB; env names `^[A-Za-z_][A-Za-z0-9_]*$`, values ≤ 1024
  chars, no null/CR/LF, protected-var overrides (PATH, HOME, …) log a warning but
  pass; working directory must exist and contain no `../` component.
- Policy violations are **returned as corrective messages** (upstream pattern), not
  thrown — the model can rephrase the command within the turn.

### Dual-use CLI

`OperationCLIDriver` over the same five declarations — single tool, so the grammar is
`<executable> <noun> <verb>`, matching the Rust `shelltool-cli` shape:

```
shell-demo command execute --command "echo hi" --timeout 30
shell-demo processes list
shell-demo history grep --pattern "error" --limit 20
shell-demo lines get --command-id 3 --start 40 --end 80
shell-demo process kill --id 3
```

Help, did-you-mean, and completion scripts come from stock ArgumentParser. Note the
per-session history consequence: each CLI invocation is a fresh process (fresh session
id), so `history grep` in one invocation cannot see a prior invocation's output — true
of the Rust CLI too. The example's `--script` mode (§6) runs a sequence of ops in one
process to make the history ops demonstrable from the command line.

## 4. How it reaches a session

```swift
let context = ShellContext(
    state: ShellState(),                      // .shell resolution + fresh session
    policy: ShellPolicy(),                    // stacked config, loaded per call
)
let shellTool = try ShellTool.make(context: context)   // OperationTool<ShellContext>

let session = LanguageModelSession(
    tools: [shellTool],
    instructions: "…you have a shell; run commands, then grep/get lines from history…"
)
```

Five ops sits comfortably inside upstream's 5–15 op guidance for one fused tool. The
`--chat` example measures the rendered schema with `tokenCount(for:)` and exercises the
canonical loop: *execute → tail is truncated → `get lines` / `grep history` for the
rest* — the workflow the tool exists for.

## 5. Resolved decisions

1. **Build on `FoundationModelsOperations`** — inherit schema fusion, resolver,
   return-don't-throw + retry cap, `includesSchemaInInstructions`, CLI driver. Our five
   ops use the `@Operation` macro (they are plain structs; no reason for the manual
   path).
2. **Op strings match sah exactly** (`execute command`, `list processes`,
   `kill process`, `grep history`, `get lines`); missing `op` still defaults to
   `execute command` via a tool-level inference hook (upstream's opt-in closure) —
   the Rust tool's empty-op default, expressed in the port's idiom.
3. **Typed `Encodable` outputs, not preformatted text** (§8.1).
4. **swift-subprocess for spawning**, process group per command; posix_spawn fallback
   recorded (§7.2).
5. **macOS 26+ only.** No iOS stub.
6. **Security layer ported whole**, including the stacked YAML config and the exact
   builtin deny list; Yams dependency accepted.
7. **grep default `limit` = 10, documented as 10** — the Rust code's effective
   behavior wins over its stale doc string (§8.3).
8. **`max_line_length` dropped** — declared but never enforced in Rust; we don't port
   a dead knob (§8.4).
9. **No tolerant string-int parsing** — guided generation constrains the model to the
   declared integer types, and the CLI parses typed; the Rust workaround existed for
   MCP clients that stringify ints, a client class this package doesn't have (§8.2).
10. **History is per-session (per process), log unbounded** — parity. Documented, with
    the `--script` demo mode as the CLI-side mitigation.
11. **Session id is a UUID** (Rust uses a ULID; nothing reads the id's structure —
    it's only a log-line namespace) (§8.5).
12. **Kill is SIGKILL, immediately** — parity with the Rust `kill process` op (the
    graceful SIGTERM→SIGKILL escalation in the Rust guard is internal cleanup, not op
    behavior).

## 6. Examples (`./Examples`)

Mirrors the upstream `NotesTool` / `skills-demo` shape: one thin executable target
(`shell-demo`) in the root `Package.swift`, three modes:

- **default — CLI** (§3's grammar) over a real `.shell` store in the cwd.
- **`--chat`** — a `LanguageModelSession` with the fused tool (gated on model
  availability; skips gracefully otherwise). Scripted prompts drive the full loop:
  run a command with long output → model sees the 32-line tail note → prompts nudge it
  to `grep history` and `get lines`; also start a `sleep 60 &`-style long command,
  `list processes`, `kill process`. Reports op-call accuracy, rendered schema size via
  `tokenCount(for:)`, and retry-cap behavior on a deliberately denied command
  (`sudo rm -rf /` → corrective message → model rephrases).
- **`--script`** — reads op lines from stdin and executes them sequentially **in one
  process**, so `execute` → `grep` → `get lines` chains work from a terminal; doubles
  as the human-driven twin of the integration tests.

## 7. Risks & verification points

1. **Process-group control via swift-subprocess** — the load-bearing assumption is
   that its platform options can place the child in its own group (or expose enough
   pid to `setpgid`/`killpg` reliably). Verified first, in task 3, with the
   kill-the-whole-tree test; if it can't, fall back to a small posix_spawn wrapper
   (`POSIX_SPAWN_SETPGROUP`, pipes via file actions, `waitpid` off-actor) — the
   design is unchanged, only the spawn call.
2. **Zombie/reap discipline** — every exit path (normal, timeout, kill, task
   cancellation) must reap the child. Pinned by tests that assert no lingering
   process after each path.
3. **Actor availability during long commands** — `list processes` / `kill process`
   must respond while an `execute command` is running. Pinned by an explicit
   concurrent test (start `sleep 5`, then kill it via the op, assert duration ≪ 5 s).
4. **Model behavior with the shell vocabulary** — nothing here is riskier than the
   NotesTool validation already proved, but `command` values are free-form strings
   with quoting; the `--chat` harness checks the model actually produces runnable
   commands and follows the tail → `get lines` breadcrumb.
5. **Toolchain** — Xcode 26 / macOS 26 SDK; tests construct
   `GenerationSchema`/`GeneratedContent`, so CI needs macOS 26 runners (same
   constraint and scope as upstream: build + non-model tests in CI, live-model runs
   manual).

## 8. Departures from the Rust design (recorded, DESIGN_NOTES-style)

1. **Typed JSON outputs instead of preformatted text blocks.** Upstream
   `AnyOperation` JSON-encodes every output; embedding sah's text tables in a JSON
   string would double-escape them. Field names and the `"{n}: {text}"` line format
   are preserved inside the JSON so nothing the model needs to learn is lost.
2. **No tolerant string-int parsing.** FoundationModels guided generation constrains
   sampling to the declared schema types — the "client sends `"60"` for an int"
   failure class the Rust helpers guard against cannot occur on the model path, and
   ArgumentParser types the CLI path.
3. **grep `limit` defaults to 10 and says so.** Rust's param description claims 50
   but the code defaults 10; we ship the observed behavior with an honest
   description.
4. **`max_line_length` (2000) not ported** — declared but unenforced in the Rust
   `OutputBuffer`; the 10 MiB total cap is the real limit and is ported exactly.
5. **UUID session ids** (ULID in Rust) — the id is an opaque log namespace; no
   ordering property is used; not worth a dependency.
6. **macOS-only** — the Rust tool has Windows arms (`cmd /C`, `taskkill`); this
   package's platform is fixed by FoundationModels + `sh` anyway.
7. **Free upgrades from upstream, absent in Rust `shell`:** op/verb aliases and
   key-case normalization (Rust shell declared none), corrective-message retry cap,
   and `includesSchemaInInstructions` control.

## 9. Tasks

Ordering is a dependency graph; each task is independently verifiable with
`swift test`.

### 1. Package scaffolding
**What:** `Package.swift` (tools 6.2, macOS 26, deps: `FoundationModelsOperationTool`
branch `main`, `swift-subprocess`, `Yams`), targets per §3 layout, CI workflow
(`swift build && swift test`, macOS 26 runner), `.shell/`-aware `.gitignore`.
**Accept:** builds; placeholder test passes in the test target.

### 2. `ShellState` + log store
**What:** the actor, `.shell` dir resolution (cwd → temp fallback), `.gitignore`
seeding, `CommandRecord`, monotonic ids, `appendLines` (stdout-then-stderr, continuing
counter, `{session}:{cmd}:{n}:{text}` format), `completeCommand`, `killProcess`
bookkeeping, `getLines`, `grep` (Swift `Regex`, `literal` escaping, `commandId`
filter, limit + total).
**Tests:** temp-dir round-trips; id and line numbering (incl. stderr continuation);
per-session filtering (foreign session lines invisible); grep limit/total split;
invalid-regex error; `getLines` defaults and unknown-id-empty; read-only-cwd fallback.
**Depends on:** 1.

### 3. `ShellRunner` (spawn / stream / limits / timeout / kill)
**What:** swift-subprocess integration — `sh -c`, own process group, null stdin,
concurrent line streaming into `OutputBuffer` (10 MiB cap, line-boundary truncation +
marker, 8 KiB binary sniff, UTF-8-lossy), timeout race with group-SIGKILL, group-kill
helper for the kill op, guaranteed reap on all exit paths.
**Tests:** echo round-trip; exit codes (0, 2, signal → −1); env-add-on-top; working
dir; timeout kills a `sleep`-spawning tree entirely (no survivors, no zombies);
truncation at exactly-over-limit; binary placeholder; interleaved stderr ordering.
**Depends on:** 1. *(Task 3 resolves risk §7.1 first — the pgid spike happens here.)*

### 4. `ShellPolicy` (stacked config + validation)
**What:** Yams-parsed three-layer config (embedded builtin with sah's exact deny
list, user, project-git-root), permit-then-deny evaluation, fresh load per call,
command-length / env-var / working-directory validation, `enable_validation` switch.
**Tests:** table-driven — every builtin deny pattern blocks its exemplar and allows a
near-miss; permit short-circuits deny; layer setting override + list concatenation;
env name/value/protected-var cases; `../` rejection; missing config files are fine.
**Depends on:** 1.

### 5. The five operations + `ShellTool.make()`
**What:** `@Generable @Operation` structs (`ExecuteCommand`, `ListProcesses`,
`KillProcess`, `GrepHistory`, `GetLines`) with `@Guide` descriptions and the §3 typed
outputs; `ShellContext`; execute pipeline (policy → run → store → result with 32-line
tail + note); the missing-`op` → `execute command` inference hook; fusion via
`OperationTool` with tool name `"shell"`.
**Tests:** dispatch through `AnyOperation` for each op; snake_case payload parity
(`working_directory`, `command_id`); corrective messages for missing required params,
unknown kill id, denied command; tail-note appears only past 32 lines; the concurrent
list/kill-while-running test (risk §7.3); output struct JSON shapes.
**Depends on:** 2, 3, 4.

### 6. CLI driver wiring
**What:** `OperationCLIDriver` over the tool in the example executable; exit codes;
JSON printing.
**Tests:** argv → payload round-trip equals the model-path payload for every op
(upstream's convergence contract); help snapshots; unknown noun/verb did-you-mean.
**Depends on:** 5.

### 7. Example: `shell-demo` (CLI / `--chat` / `--script`)
**What:** the §6 executable; scripted chat harness (availability-gated) validating
the execute → grep/get-lines loop, list/kill on a long-running command, the denied-
command corrective path, and schema token cost; `--script` sequential mode.
**Tests:** integration tests driving every op through `AnyOperation` and the CLI; the
live-model path is manual-run but scripted (`swift run shell-demo --chat`).
**Depends on:** 5, 6.

### 8. Docs
**What:** README (declare → fuse → session → CLI, library-style with a runnable
example), DocC comments on public API, §8's departures cross-referenced.
**Accept:** README snippets are doc-snippet-tested against the example source
(upstream's mechanism).
**Depends on:** 7.

## 10. Testing

The unit tier is GPU-free and hermetic: state/log tests run against temp directories;
runner tests spawn real `sh` children (fast, deterministic commands); policy tests are
pure tables; dispatch tests use the real fused tool with a real (temp-dir) context —
no mocks of our own layers. The only mocked boundary is none: unlike the Skills
package there is no sibling-service seam here — the shell *is* the effect.

**Concurrency is an explicit, named test case, not incidental coverage:** start a
long command, assert `list processes` shows it `running` with a `+`-style live
duration, `kill process` it, assert the record flips to `killed` with lines captured,
and the process tree is gone — end to end through op dispatch.

The live-model tier (manual, availability-gated) is the `--chat` harness (§6), the
same pattern as upstream's `ChatValidationHarness`.

---

### Sources
- Rust reference: `../swissarmyhammer` — `crates/swissarmyhammer-tools/src/mcp/tools/shell/`
  (ops, state, process guard), `crates/swissarmyhammer-shell` (security config),
  `builtin/shell/config.yaml` (deny list), `apps/shelltool-cli` (CLI shape)
- FoundationModelsOperationTool plan + DESIGN_NOTES (upstream pattern, schema-fusion
  evidence, return-don't-throw, CLI registry) — ../FoundationModelsOperationTool/plan.md
- FoundationModelsSkills plan (ecosystem conventions: ops tables, Examples-as-fixtures,
  decision log) — ../FoundationModelsSkills/plan.md
- FoundationModelsAgents plan (root-package example-target convention) —
  ../FoundationModelsAgents/plan.md
- swift-subprocess (SF-0007) — https://github.com/apple/swift-subprocess
- Yams — https://github.com/jpsim/Yams
- What's new in Foundation Models (WWDC26) — https://developer.apple.com/videos/play/wwdc2026/241/
