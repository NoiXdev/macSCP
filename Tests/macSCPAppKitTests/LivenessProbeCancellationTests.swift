import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the fix for the whole-branch final review's finding I-1: a probe
/// that was cancelled — or whose session went away — while its `stat` was in
/// flight writes NOTHING onto the tab.
///
/// The defect was reachable because `LivenessProbeRace.run` is deliberately
/// not cancellation-aware (see its own doc comment): cancelling the probing
/// task does not shorten it, so the task resumes after its own cancellation,
/// up to a full `LivenessProbePolicy.probeTimeout(forInterval:)` later, and
/// the write that used to sit straight after the `await` landed on a tab
/// `teardown(_:)` had already cleared. The reviewer reproduced that shape
/// standalone and measured the write arriving 2.04s after the cancel.
///
/// This suite drives the REAL race, really cancelled, through the real
/// `LivenessProbeStep.perform` — the function the probe loop now calls in
/// place of an inline race-then-write. What it cannot drive is the loop
/// itself: `LivenessProbeRunner`'s `.task(id:)` body needs a SwiftUI
/// rendering harness this project does not have, which is why the loop's own
/// half of the fix (routing through this function, and stopping rather than
/// continuing on `.abandoned`) is pinned by `LivenessProbeWiringGuardTests`
/// instead.
///
/// `theTabIsWrittenWhenNothingIntervenes` is the control that keeps the
/// three refusals from being vacuous: a `perform` that returned
/// `.abandoned` unconditionally, or never wrote at all, would satisfy every
/// one of them.
///
/// Isolation: no `ContentView`, no store of any kind, no network. The fake
/// file system this suite hands its sessions never answers and never touches
/// disk, and the deadline is the shortest `probeTimeout(forInterval:)` can
/// produce.
@Suite("Liveness probe cancellation", .timeLimit(.minutes(1)))
@MainActor
struct LivenessProbeCancellationTests {
    /// The shortest deadline the shipped policy can produce
    /// (`probeTimeout(forInterval:)` floors at 1), so these tests wait out a
    /// real race rather than a stubbed one without costing more than that.
    private let timeoutSeconds = 1

    @Test func aCancelledProbeWritesNothing() async throws {
        let tab = makeTab()
        let remoteFS = attachSession(to: tab)
        tab.liveness = .connected

        let start = ContinuousClock.now
        let probe = Task { await LivenessProbeStep.perform(on: tab, timeoutSeconds: timeoutSeconds) }
        try await waitUntilTheProbeIsInFlight(remoteFS)
        // What `teardown(_:)` does, in the order it does it: the tab stops
        // describing a live connection, and the runner's task is dropped.
        // The session is deliberately LEFT in place here, so the only thing
        // that can refuse the write is the cancellation check itself —
        // `aProbeWhoseSessionWentAwayWritesNothing` covers the other
        // half of the guard on its own.
        tab.liveness = nil
        probe.cancel()
        let result = await probe.value
        let elapsed = start.duration(to: .now)

        #expect(result == .abandoned)
        #expect(tab.liveness == nil, """
            a probe wrote \(String(describing: tab.liveness)) onto a tab after its own \
            cancellation — the write must be refused between the race and the tab, because \
            the race cannot be cut short.
            """)
        // The window is real, not an artefact of cancelling early: the
        // cancel does NOT shorten the race, so the answer this test refuses
        // arrives a full deadline after the probe started, long after the
        // tab was cleared. Without this the suite would still pass against a
        // race that happened to be cancellation-aware, which is exactly what
        // this one is not.
        //
        // Measured from the START of the probe rather than from the cancel,
        // and against a lower bound only: under this package's parallel
        // execution, "how much of the deadline was left when the cancel
        // arrived" is a quantity contention can shrink, while the whole run
        // cannot go BELOW the deadline unless the race returned early —
        // which is the only thing this assertion is here to rule out. Same
        // reasoning, and the same margin under a 1s deadline, as
        // `LivenessProbeRaceTests
        // .aStatThatNeverRespondsStillReportsFailureWithinTheDeadline`.
        #expect(elapsed >= .milliseconds(900), """
            the probe returned after \(elapsed), inside its own \(timeoutSeconds)s deadline \
            — cancelling the task around the race was expected not to shorten it.
            """)
    }

    @Test func aProbeWhoseSessionWentAwayWritesNothing() async throws {
        let tab = makeTab()
        let remoteFS = attachSession(to: tab)
        tab.liveness = .connected

        let probe = Task { await LivenessProbeStep.perform(on: tab, timeoutSeconds: timeoutSeconds) }
        try await waitUntilTheProbeIsInFlight(remoteFS)
        // Disconnected and reconnected during the flight: the task is alive
        // and uncancelled, and the answer in hand is nevertheless about a
        // connection that no longer exists.
        attachSession(to: tab)
        tab.liveness = .connecting

        let result = await probe.value

        #expect(result == .abandoned)
        #expect(tab.liveness == .connecting, """
            a probe wrote \(String(describing: tab.liveness)) over the state of a session \
            that replaced the one it was probing.
            """)
    }

    @Test func aProbeWithNoSessionAtAllWritesNothing() async {
        let tab = makeTab()
        tab.liveness = nil

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: timeoutSeconds)

        #expect(result == .abandoned)
        #expect(tab.liveness == nil)
    }

    /// The control. A peer that never answers, left alone to run its
    /// deadline out, DOES leave the tab `.degraded` and reports `.failed` —
    /// so the three refusals are refusals of a write that would otherwise
    /// happen, not descriptions of a function that never writes.
    @Test func theTabIsWrittenWhenNothingIntervenes() async {
        let tab = makeTab()
        attachSession(to: tab)
        tab.liveness = .connected

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: timeoutSeconds)

        #expect(result == .failed)
        #expect(tab.liveness == .degraded)
    }

    // MARK: - Fixtures

    /// Same shape as `LivenessGiveUpOrderingTests.makeTab()`.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Waits until the probe has actually reached the `stat` it will hang
    /// on, instead of sleeping a guessed interval and hoping.
    ///
    /// A fixed sleep was the first shape here and it was wrong: under this
    /// package's parallel execution a 150ms sleep was measured taking most
    /// of a second, which would let the race resolve on its own BEFORE the
    /// cancel arrived — a passing test turning into a failing one on
    /// scheduler contention alone, proving nothing either way. Polling
    /// until the file system says the call arrived costs whatever it costs
    /// and cannot overshoot.
    ///
    /// No bound of its own, either: a `stat` that never arrives ends this
    /// run through the suite's `.timeLimit`, which prints the name of the
    /// wait, rather than through a ceiling that measures the runner
    /// (CLAUDE.md, "A wall-clock ceiling in a test measures the runner").
    private func waitUntilTheProbeIsInFlight(_ remoteFS: NeverRespondingFileSystem) async throws {
        try await pollUntil("the probe reaching stat") { remoteFS.statHasBeenCalled }
    }

    /// Same shape as `LivenessGiveUpOrderingTests.attachSession(to:)`, with
    /// the one difference this suite needs: a remote file system whose
    /// `stat` never answers, so the probe is still suspended inside the race
    /// when the cancel arrives. It is returned rather than dropped because
    /// that is how a test knows the probe got that far. Called twice by
    /// `aProbeWhoseSessionWentAwayWritesNothing`, which is what gives that
    /// test a second session with a fresh id.
    @discardableResult
    private func attachSession(to tab: SessionTab) -> NeverRespondingFileSystem {
        let sessionID = UUID()
        let remoteFS = NeverRespondingFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSTemporaryDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        return remoteFS
    }
}

/// A `RemoteFileSystem` whose `stat` never resumes — the same shape
/// Citadel's own NIO bridge has against a silently dead connection, and the
/// only case in which the post-cancellation window is wide enough to
/// observe. File-local, like every other test double in this target, for the
/// reason `LivenessGiveUpOrderingTests` gives for its own: `macSCPAppKitTests`
/// cannot import `macSCPCoreTests`. `LivenessProbeRaceTests` keeps a private
/// double of the same name and shape; that duplication is an instance of the
/// shared-test-support-target gap this project already carries in its
/// backlog, not a difference in behaviour.
///
/// Everything except `stat` traps if called, so a future change that routes
/// through one of them fails loudly instead of passing quietly.
private final class NeverRespondingFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var statArrived = false

    /// Whether the probe's `stat` has arrived — the signal
    /// `LivenessProbeCancellationTests.waitUntilTheProbeIsInFlight(_:)`
    /// waits on, so a test cancels a probe that is genuinely suspended
    /// rather than one it hopes is. Locked rather than plain, because the
    /// race runs the operation as its own task.
    var statHasBeenCalled: Bool { lock.withLock { statArrived } }

    func list(path: String) async throws -> [RemoteFileItem] {
        fatalError("not exercised by this test")
    }

    func stat(path: String) async throws -> RemoteFileItem {
        lock.withLock { statArrived = true }
        return try await withCheckedThrowingContinuation {
            (_: CheckedContinuation<RemoteFileItem, Error>) in
            // Deliberately never resumed.
        }
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        fatalError("not exercised by this test")
    }

    func delete(path: String) async throws {
        fatalError("not exercised by this test")
    }

    func createDirectory(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func rename(from: String, to: String) async throws {
        fatalError("not exercised by this test")
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }

    func deleteTree(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func homeDirectoryPath() async throws -> String {
        fatalError("not exercised by this test")
    }

    func disconnect() async {}
}
