// `RunSupervisor` — tracks the unstructured `Task` handles `ShellRunner`
// detaches when a `run(_:wait:)` call's `wait` deadline elapses (or its
// caller is cancelled) before the child exits.
//
// It exists purely for bookkeeping: an unstructured `Task` keeps running
// whether or not anything holds its handle, so nothing here is load-bearing
// for the detached child's own supervision (that guarantee is `runBody`'s —
// see `ShellRunner`'s file header). What this type adds is visibility into
// which commands are currently running in the background, and a single place
// that owns their `Task` handles.
//
// A lock-based type (`Mutex`), not an actor, for the same reason as
// `ProcessRegistry`: `track`/`untrack` are ordinary synchronous calls, usable
// from any concurrency domain without an `await` hop.

import Foundation
import Synchronization

/// Tracks the in-flight background `Task` for each command whose body is
/// running detached from the `run(_:wait:)` call that started it, keyed by
/// command id.
///
/// `ShellRunner` tracks a command's task here the moment its body starts —
/// before any deadline race — and the task itself untracks on its own
/// completion (success, timeout, or an external kill), so at any instant
/// `trackedCommandIDs` mirrors exactly the commands still executing.
final class RunSupervisor: Sendable {
    /// The tracked background tasks, guarded by a lock rather than an actor
    /// so `track`/`untrack` never need an `await` hop.
    private let tasks = Mutex<[Int: Task<Void, Never>]>([:])

    /// Create an empty supervisor. Each `ShellRunner` gets its own by
    /// default; nothing about supervision needs process-wide sharing (unlike
    /// `ProcessRegistry.global`, there is no `atexit` backstop here — the
    /// child's own no-leak guarantee never depends on this bookkeeping).
    init() {}

    /// Start tracking `task` as the background supervisor for `commandID`.
    func track(commandID: Int, task: Task<Void, Never>) {
        tasks.withLock { $0[commandID] = task }
    }

    /// Stop tracking `commandID`. A no-op if it isn't currently tracked
    /// (e.g. called twice, or for an id nothing ever tracked).
    func untrack(_ commandID: Int) {
        tasks.withLock { _ = $0.removeValue(forKey: commandID) }
    }

    /// The command ids currently supervised in the background.
    var trackedCommandIDs: Set<Int> {
        tasks.withLock { Set($0.keys) }
    }
}
