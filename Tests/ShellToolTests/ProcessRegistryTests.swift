import Foundation
import Testing

@testable import ShellTool

/// Behavioral tests for `ProcessRegistry` and the parameterized `sweep(_:)`
/// backstop.
///
/// Every test here constructs its own **private** `ProcessRegistry()` — never
/// `ProcessRegistry.global` — so a sweep can never reach into another
/// concurrently running test suite's live processes (swift-testing runs a
/// package's test suites concurrently in one process; see
/// `ProcessRegistry.global`'s doc comment).
@Suite struct ProcessRegistryTests {

    /// Failure spawning the child used by the sweep tests.
    private enum SpawnError: Error { case attrInit, spawn(Int32) }

    /// Spawn a real, long-lived `/bin/sleep` child in its **own** process group
    /// (so its process-group id equals its pid) — the same shape `ShellRunner`
    /// spawns commands in (`POSIX_SPAWN_SETPGROUP`), mirrored here at the raw
    /// `posix_spawn` level (the established pattern `ShellStateTests
    /// .spawnKillableChild` already uses). Returns the child's pid, which
    /// doubles as its process-group id.
    private func spawnKillableChild(seconds: String = "60") throws -> pid_t {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw SpawnError.attrInit }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let path = "/bin/sleep"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(seconds), nil]
        defer { for case let arg? in argv { free(arg) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
        guard rc == 0 else { throw SpawnError.spawn(rc) }
        return pid
    }

    // MARK: - register/deregister lifecycle

    @Test func registerThenDeregisterTracksLiveMembership() {
        let registry = ProcessRegistry()
        let pid: pid_t = 424_242
        #expect(registry.registeredPids.isEmpty)

        registry.register(pid)
        #expect(registry.registeredPids == [pid])

        registry.deregister(pid)
        #expect(registry.registeredPids.isEmpty)
    }

    @Test func deregisteringAnUnregisteredPidIsANoOp() {
        let registry = ProcessRegistry()
        registry.deregister(999_999)
        #expect(registry.registeredPids.isEmpty)
    }

    // MARK: - sweep(_:) kills every still-registered group

    /// The load-bearing test: `sweep(_:)` on a **private** registry with a
    /// live child pgid `killpg`s it dead.
    @Test func sweepKillsALiveChildInAPrivateRegistry() throws {
        let registry = ProcessRegistry()
        let pid = try spawnKillableChild()
        registry.register(pid)

        // Genuinely alive before the sweep.
        #expect(kill(pid, 0) == 0)

        sweep(registry)

        // Genuine round-trip: reap (blocks until it exits — no timing races)
        // and confirm SIGKILL actually terminated it.
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, 0)
        #expect(reaped == pid)
        #expect((status & 0x7f) == SIGKILL)
    }

    // MARK: - ESRCH tolerance

    /// An already-dead pid in the registry must not abort the sweep: the rest
    /// of the registered set — a genuinely live pid here — still gets killed.
    @Test func sweepToleratesAnAlreadyDeadPidAndStillKillsOtherLiveMembers() throws {
        let registry = ProcessRegistry()

        // A genuinely live child.
        let livePid = try spawnKillableChild()
        registry.register(livePid)

        // An already-dead pid, registered alongside it: spawn and reap a
        // short-lived child up front so its pid is guaranteed gone before the
        // sweep runs.
        let deadPid = try spawnKillableChild(seconds: "0")
        var reapStatus: Int32 = 0
        _ = waitpid(deadPid, &reapStatus, 0)
        #expect(kill(deadPid, 0) == -1 && errno == ESRCH, "expected \(deadPid) to already be gone")
        registry.register(deadPid)

        // Must not throw/crash despite the stale ESRCH pid, and must still
        // reach and kill the genuinely live one.
        sweep(registry)

        var status: Int32 = 0
        let reaped = waitpid(livePid, &status, 0)
        #expect(reaped == livePid)
        #expect((status & 0x7f) == SIGKILL)
    }
}
