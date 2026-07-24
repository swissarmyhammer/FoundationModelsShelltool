// `ProcessRegistry` — the no-leak backstop for process groups `ShellRunner`
// spawns, split out as a precursor so it lands and tests independently
// against today's blocking `ShellRunner.run`, before anything detaches from
// it.
//
// It is a plain, lock-based registry, not an actor: `register`/`deregister`
// must be callable from ordinary synchronous, non-`async` contexts — notably
// the `atexit` closure below, which cannot `await` anything — so a
// `Mutex<Set<pid_t>>` (`Synchronization`) backs it instead. Nothing about it
// is actor-isolated, so every member is `nonisolated`ly reachable from any
// concurrency domain without a hop.
//
// `ProcessRegistry.global` is the process-wide instance production
// `ShellRunner`s default to, wired to a best-effort `atexit` sweep (installed
// exactly once, on first access) that kills any process group still alive at
// normal process exit. Tests must always construct and pass their own
// private `ProcessRegistry()` when they need to observe or sweep registry
// state: swift-testing runs a package's test suites concurrently in one
// process, so sweeping the *shared* global registry mid-run could `killpg` a
// pid a different, still-live test suite owns. In practice `sweep` is never
// invoked against `.global` anywhere but the `atexit` closure below — this
// file is the only place that wires the two together — so that hazard can't
// actually occur; private-instance-only test discipline just keeps it that
// way even as the suite grows.

import Foundation
import Synchronization

/// A lock-based registry of live process-group leader pids.
///
/// `ShellRunner` registers a spawned child's pid here right after it starts,
/// and deregisters it once its own per-run teardown has already `killpg`'d
/// the group — so under ordinary operation this registry is just a
/// live-accounting ledger, empty between runs. `sweep(_:)` is the backstop
/// for whatever a *normal* process exit still finds registered (see the file
/// header, and `ProcessRegistry.global`'s doc comment, for that guarantee's
/// limits).
final class ProcessRegistry: Sendable {
    /// The live process-group leader pids, guarded by a lock rather than an
    /// actor so synchronous, non-`async` callers (the `atexit` closure this
    /// file installs) can register, deregister, and sweep without an
    /// `await`.
    private let pids = Mutex<Set<pid_t>>([])

    /// Create an empty registry. Production `ShellRunner`s should generally
    /// use `ProcessRegistry.global`; tests should always construct their own
    /// private instance (see the file header).
    init() {}

    /// Register `pid` — a process-group leader (pgid == pid), matching how
    /// `ShellRunner` spawns children — as live.
    func register(_ pid: pid_t) {
        pids.withLock { _ = $0.insert(pid) }
    }

    /// Deregister `pid`. A no-op if it isn't currently registered (e.g.
    /// called twice, or for a pid nothing ever registered).
    func deregister(_ pid: pid_t) {
        pids.withLock { _ = $0.remove(pid) }
    }

    /// A snapshot of every pid currently registered — what `sweep(_:)` kills,
    /// and what tests assert against.
    var registeredPids: Set<pid_t> {
        pids.withLock { $0 }
    }
}

/// Sends `SIGKILL` to the process group of every pid currently registered in
/// `registry` — a parameterized sweep, deliberately never hardcoded to
/// `ProcessRegistry.global`, so it can be exercised against a private,
/// test-owned registry without any risk of reaching a pid it doesn't own.
///
/// An already-dead pid's `killpg` fails with `ESRCH`; that failure is
/// silently tolerated — sweeping a registry that includes an already-reaped
/// process is the expected steady state (every `ShellRunner` run already
/// tears its own group down via `defer`), not an error — and sweeping
/// continues on to the rest of the registered set. `sweep` does not itself
/// deregister anything: it is a last-resort backstop, not part of the normal
/// register/deregister lifecycle.
func sweep(_ registry: ProcessRegistry) {
    for pid in registry.registeredPids {
        _ = killpg(pid, SIGKILL)
    }
}

/// The process-wide registry the `atexit` sweep below targets. Referenced
/// **only** from the installer immediately below it — see
/// `ProcessRegistry.global`'s doc comment for why nothing else should touch
/// it.
private let globalProcessRegistry = ProcessRegistry()

/// Installs the `atexit` sweep of `globalProcessRegistry`. Swift initializes
/// top-level `let`s lazily, thread-safely, and exactly once on first access,
/// so `ProcessRegistry.global` triggers this installer by simply referencing
/// `globalProcessRegistrySweepInstalled` below — no explicit locking needed
/// here, and the closure is installed exactly once no matter how many times
/// `.global` is accessed.
///
/// The closure passed to `atexit` must capture nothing (a C function pointer
/// can't carry captured context), so it references `globalProcessRegistry`
/// directly as a top-level global rather than a locally captured variable.
@discardableResult
private func installGlobalProcessRegistrySweep() -> Bool {
    atexit {
        sweep(globalProcessRegistry)
    }
    return true
}

/// Forces `installGlobalProcessRegistrySweep()` to run exactly once, the
/// first time anything accesses `ProcessRegistry.global`.
private let globalProcessRegistrySweepInstalled = installGlobalProcessRegistrySweep()

extension ProcessRegistry {
    /// The process-wide registry production `ShellRunner`s register into by
    /// default, backstopped by an `atexit`-installed sweep (installed exactly
    /// once, on first access to this property) that kills any process group
    /// still registered at normal process exit.
    ///
    /// **Limitation, stated honestly:** `atexit` only runs on a *normal*
    /// process exit (returning from `main`, or an explicit `exit(_:)`) — it
    /// does **not** run on `SIGKILL` or a crash. This narrows, but does not
    /// replace, `ShellRunner`'s own per-run `defer` teardown, which is what
    /// actually guarantees a spawned child's group dies on every ordinary run
    /// exit path (normal completion, timeout, cancellation, or a thrown
    /// error) long before the process itself ever exits. This registry has
    /// something to sweep exactly when a command detached via `waitSeconds`
    /// is still running as the process exits normally: a detached command's
    /// pid stays registered until its supervision body's `defer` teardown
    /// runs, so a normal exit mid-detach is precisely the gap the sweep
    /// closes (DESIGN_NOTES §15).
    ///
    /// Never reach for this in a test: swift-testing runs a package's test
    /// suites concurrently in one process, so sweeping this shared registry
    /// could `killpg` a pid a *different*, still-running test suite owns.
    /// Construct a private `ProcessRegistry()` instead.
    static var global: ProcessRegistry {
        _ = globalProcessRegistrySweepInstalled
        return globalProcessRegistry
    }
}
