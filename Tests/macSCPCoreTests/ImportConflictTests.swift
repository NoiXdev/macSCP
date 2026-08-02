import Foundation
import Testing
@testable import macSCPCore

/// Cancellation-INDEPENDENT one-shot signal (mirrors `PlainSignal` in
/// `RemoteBrowserViewModelTests`/`TerminalPanelViewModelTests`, duplicated
/// per file per that established convention): `wait()` ignores task
/// cancellation on the waiting side, which is exactly what the concurrency
/// tests below need to park a decider mid-flight deterministically.
private final class PlainSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Records which conflicts the decider was actually asked about, in order.
/// File-scoped and privately named (not `Counter`) so this suite cannot
/// collide with — or be broken by a rename of — the module-level `Counter`
/// actor declared in `TerminalPanelViewModelTests.swift`.
private actor DeciderCallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

@Suite("ImportConflictArbiter")
struct ImportConflictTests {
    @Test func asksOncePerConflictWithoutApplyToAll() async {
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            return (.skip, false)
        }
        _ = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        _ = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(await log.names.count == 2)
    }

    @Test func applyToAllAnswersEveryFurtherConflictWithoutAsking() async {
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            return (.replace, true)
        }
        let first = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        let second = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(first == .replace)
        #expect(second == .replace)
        #expect(await log.names.count == 1)
    }

    /// Same two-call shape as `applyToAllAnswersEveryFurtherConflictWithoutAsking`
    /// so stickiness is proven behaviourally, not just via the flag: a
    /// mutant that records `isCancelled` but never re-checks it at the top
    /// of `resolve` would ask the decider again on the second call and this
    /// test would catch it (the previous single-call version did not).
    @Test func nilCancelsAndStaysCancelledWithoutAskingAgain() async {
        let log = DeciderCallLog()
        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            return nil
        }
        let first = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        let second = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(first == nil)
        #expect(second == nil)
        #expect(await arbiter.isCancelled)
        #expect(await log.names.count == 1)
    }

    // MARK: - Concurrency (reentrancy across the `await decider(...)` suspension)

    /// Two `resolve` calls are driven concurrently with genuinely suspending
    /// deciders (via `PlainSignal`, no sleep): both are parked inside their
    /// own `await decider(...)` at the same time, so both observe
    /// `rule == nil` — the exact reentrancy window actor isolation does not
    /// protect. Call "a" is let through first and answers `applyToAll`;
    /// call "b" is then let through with a DIFFERENT, non-rule answer.
    /// Correct behaviour: "b" must return "a"'s rule, not its own answer —
    /// that is what "don't ask again" means once a rule exists.
    @Test func applyToAllRuleWinsOverAConcurrentlySuspendedCallsOwnAnswer() async {
        let log = DeciderCallLog()
        let aStarted = PlainSignal()
        let aMayReturn = PlainSignal()
        let bStarted = PlainSignal()
        let bMayReturn = PlainSignal()

        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            if conflict.itemName == "a" {
                aStarted.fire()
                await aMayReturn.wait()
                return (.replace, true)   // applyToAll
            } else {
                bStarted.fire()
                await bMayReturn.wait()
                return (.skip, false)     // a different, non-rule answer
            }
        }

        let taskA = Task { await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set")) }
        await aStarted.wait()

        let taskB = Task { await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set")) }
        await bStarted.wait()
        // Both calls are now genuinely suspended inside their own decider
        // invocation, with `rule` still nil for both.

        aMayReturn.fire()
        let resultA = await taskA.value
        #expect(resultA == .replace)

        bMayReturn.fire()
        let resultB = await taskB.value

        #expect(resultB == .replace)             // must defer to "a"'s rule, not return .skip
        #expect(await log.names == ["a", "b"])   // both were genuinely asked — that overlap is expected
    }

    /// Same reentrancy window, but call "a" cancels (decider returns nil)
    /// while call "b" is still suspended inside its own `await
    /// decider(...)`. Correct behaviour: "b" must return nil once it
    /// resumes, discarding its own (already-collected) answer, and the
    /// cancellation must not be undone.
    @Test func cancelWinsOverAConcurrentlySuspendedCallsOwnAnswer() async {
        let log = DeciderCallLog()
        let bStarted = PlainSignal()
        let bMayReturn = PlainSignal()

        let arbiter = ImportConflictArbiter { conflict in
            await log.record(conflict.itemName)
            if conflict.itemName == "a" {
                return nil   // cancels — no need to block "a" itself
            } else {
                bStarted.fire()
                await bMayReturn.wait()
                return (.replace, false)
            }
        }

        let taskB = Task { await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set")) }
        await bStarted.wait()
        // "b" is now genuinely suspended inside its own decider invocation.

        let taskA = Task { await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set")) }
        let resultA = await taskA.value
        #expect(resultA == nil)
        #expect(await arbiter.isCancelled)

        bMayReturn.fire()
        let resultB = await taskB.value

        #expect(resultB == nil)                  // must defer to the cancellation, not return .replace
        #expect(await log.names == ["b", "a"])
    }
}
