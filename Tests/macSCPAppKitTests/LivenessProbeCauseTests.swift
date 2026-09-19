import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// What one probe records about its own failure (lost-connection cause,
/// 2026-09-19): `LivenessProbeStep.perform` driven with file systems whose
/// `stat` throws, hangs past the deadline, or answers — and, beside it, that
/// the transitions the probe drives are the ones they were.
///
/// Isolation as in `LivenessProbeCancellationTests`: no `ContentView`, no
/// store, no network.
@Suite("Liveness probe cause", .timeLimit(.minutes(1)))
@MainActor
struct LivenessProbeCauseTests {
    @Test func aThrownConnectionLossIsRecordedAsAClosedConnection() async {
        let tab = makeTab()
        attachSession(to: tab, stat: .throwing(RemoteFSError.connectionFailed(reason: "gone")))
        tab.liveness = .connected

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 5)

        #expect(result == .failed)
        #expect(tab.liveness == .degraded)
        guard case .error(let typeName, true)? = tab.lastProbeFailure else {
            Issue.record("expected a closed-connection error, got \(String(describing: tab.lastProbeFailure))")
            return
        }
        #expect(typeName == "RemoteFSError")
    }

    @Test func aThrownCancellationIsRecordedAsACancellation() async {
        let tab = makeTab()
        attachSession(to: tab, stat: .throwing(CancellationError()))

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 5)

        #expect(result == .failed)
        #expect(tab.lastProbeFailure == .cancelled)
    }

    /// The deadline, told apart from an answer that failed. A floor on the
    /// elapsed time and no ceiling (CLAUDE.md, "A wall-clock ceiling in a
    /// test measures the runner").
    @Test func aStatThatOutlivesTheDeadlineIsRecordedAsATimeout() async {
        let tab = makeTab()
        attachSession(to: tab, stat: .sleeping)
        let start = ContinuousClock.now

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 1)

        #expect(result == .failed)
        #expect(tab.lastProbeFailure == .timeout(seconds: 1))
        #expect(start.duration(to: .now) >= .milliseconds(900))
    }

    @Test func anAnswerClearsTheLastFailure() async {
        let tab = makeTab()
        attachSession(to: tab, stat: .answering)
        tab.lastProbeFailure = .timeout(seconds: 10)

        let result = await LivenessProbeStep.perform(on: tab, timeoutSeconds: 5)

        #expect(result == .alive)
        #expect(tab.liveness == .connected)
        #expect(tab.lastProbeFailure == nil)
    }

    /// Transitions unchanged: the loop's own policy, fed by two failures the
    /// probe now records a cause for, still gives up after exactly two —
    /// and not after one.
    @Test func twoRecordedFailuresStillGiveUpAndOneDoesNot() async {
        let tab = makeTab()
        attachSession(to: tab, stat: .throwing(RemoteFSError.connectionFailed(reason: "gone")))
        var consecutiveFailures = 0
        var actions: [LivenessProbeAction] = []
        for _ in 0..<3 {
            let action = LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: consecutiveFailures)
            actions.append(action)
            guard action != .giveUp else { break }
            if await LivenessProbeStep.perform(on: tab, timeoutSeconds: 5) == .failed {
                consecutiveFailures += 1
            }
        }
        #expect(actions == [.probe, .probeAgainNow, .giveUp])
    }

    // MARK: - Fixtures

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    private func attachSession(to tab: SessionTab, stat: ScriptedStatFileSystem.Behaviour) {
        let sessionID = UUID()
        let remoteFS = ScriptedStatFileSystem(behaviour: stat)
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
    }
}

/// A `RemoteFileSystem` whose `stat` does one scripted thing. File-local,
/// like every test double in this target (`macSCPAppKitTests` cannot import
/// `macSCPCoreTests`). Everything except `stat` traps.
///
/// `.sleeping` sleeps cancellably rather than never resuming: the race
/// cancels the losing operation, and a sleep that ends on that cancel leaves
/// no continuation behind.
private final class ScriptedStatFileSystem: RemoteFileSystem, @unchecked Sendable {
    enum Behaviour {
        case throwing(any Error)
        case sleeping
        case answering
    }

    private let behaviour: Behaviour

    init(behaviour: Behaviour) { self.behaviour = behaviour }

    func stat(path: String) async throws -> RemoteFileItem {
        switch behaviour {
        case .throwing(let error):
            throw error
        case .sleeping:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case .answering:
            return RemoteFileItem(name: "/", path: path, kind: .directory)
        }
    }

    func list(path: String) async throws -> [RemoteFileItem] { fatalError("not exercised") }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> { fatalError("not exercised") }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws { fatalError("not exercised") }
    func delete(path: String) async throws { fatalError("not exercised") }
    func createDirectory(at path: String) async throws { fatalError("not exercised") }
    func rename(from: String, to: String) async throws { fatalError("not exercised") }
    func setPermissions(path: String, permissions: UInt32) async throws { fatalError("not exercised") }
    func deleteTree(at path: String) async throws { fatalError("not exercised") }
    func homeDirectoryPath() async throws -> String { fatalError("not exercised") }
    func disconnect() async {}
}

/// The close report ends with the session it describes (fix round 1 of the
/// lost-connection cause work, review Minor 8): `TabTeardown.run` is the one
/// place every disconnect goes through, and it is where the App stops
/// listening — so a close arriving afterwards cannot write a line naming a
/// tab whose session is gone.
@Suite("Close report ends at teardown", .timeLimit(.minutes(1)))
@MainActor
struct CloseReportTeardownTests {
    @Test func teardownStopsTheCloseReport() async {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
        let sessionID = UUID()
        let remoteFS = ReportingFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSTemporaryDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in throw CancellationError() }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")

        #expect(remoteFS.stopped == false)
        await TabTeardown.run(tab, reason: .userRequested)
        #expect(remoteFS.stopped, """
            `TabTeardown.run` did not stop the connection's close report. A close arriving \
            after the teardown then logs `ssh connection closed tab=<id>` for a session this \
            tab has already left.
            """)
    }
}

/// A file system that reports transport closes and records being told to
/// stop. File-local, like every double in this target.
private final class ReportingFileSystem: RemoteFileSystem, TransportCloseReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var stoppedFlag = false

    var stopped: Bool { lock.withLock { stoppedFlag } }

    func onTransportClose(_ handler: @escaping @Sendable (TransportCloseEvent) -> Void) {}

    func stopReportingTransportClose() { lock.withLock { stoppedFlag = true } }

    func stat(path: String) async throws -> RemoteFileItem { fatalError("not exercised") }
    func list(path: String) async throws -> [RemoteFileItem] { fatalError("not exercised") }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> { fatalError("not exercised") }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws { fatalError("not exercised") }
    func delete(path: String) async throws { fatalError("not exercised") }
    func createDirectory(at path: String) async throws { fatalError("not exercised") }
    func rename(from: String, to: String) async throws { fatalError("not exercised") }
    func setPermissions(path: String, permissions: UInt32) async throws { fatalError("not exercised") }
    func deleteTree(at path: String) async throws { fatalError("not exercised") }
    func homeDirectoryPath() async throws -> String { fatalError("not exercised") }
    func disconnect() async {}
}

/// The probe no longer throws its error away (lost-connection cause,
/// 2026-09-19). Before, `LivenessProbeStep.perform` reduced its `stat` to
/// `(try? …) != nil`, and nothing could tell a closed connection from a
/// silent one.
///
/// NEGATIVE: the body of `enum LivenessProbeStep` holds no `try?` at all.
/// POSITIVE beside it, so the negative cannot go stale in silence (CLAUDE.md,
/// "Guards that name what they watch"): the same body still calls the
/// remote `stat`, and hands what it caught to the classifier — so the scan
/// is reading the probe, not an empty span.
///
/// Read through `SourceCorpus.code(of:)`, comments and string literals
/// blanked: a doc comment quoting the old `(try? …)` shape — this one
/// included — cannot trip the negative, and a comment naming the classifier
/// cannot satisfy the positive.
@Suite("Liveness probe keeps its error (guard)")
struct LivenessProbeErrorKeptGuardTests {
    private static let detailFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/ContentView+Detail.swift")

    private static let anchor = "enum LivenessProbeStep"

    /// The brace-balanced body after `anchor`, from the blanked view.
    private static func stepBody() throws -> String {
        let code = try SourceCorpus.code(of: detailFile)
        let occurrences = code.components(separatedBy: anchor).count - 1
        guard occurrences == 1 else {
            Issue.record("`\(anchor)` appears \(occurrences) times in the blanked source — re-anchor this guard.")
            return ""
        }
        let chars = Array(code)
        var i = code.distance(from: code.startIndex, to: code.range(of: anchor)!.upperBound)
        while i < chars.count, chars[i] != "{" { i += 1 }
        let start = i
        var depth = 0
        while i < chars.count {
            if chars[i] == "{" { depth += 1 }
            if chars[i] == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        return String(chars[start..<min(i + 1, chars.count)])
    }

    @Test func theProbeStillStatsAndClassifiesWhatItCaught() throws {
        let body = try Self.stepBody()
        #expect(body.contains("remoteFS.stat(path:"), """
            `LivenessProbeStep`'s body no longer calls `remoteFS.stat(path:` — the negative \
            check beside this one would now be reading a span with no probe in it.
            """)
        #expect(body.contains("LivenessProbeFailure.classify("), """
            `LivenessProbeStep`'s body no longer hands the caught error to \
            `LivenessProbeFailure.classify(` — the cause of a failed probe is being dropped again.
            """)
        #expect(body.contains("catch"))
    }

    @Test func theProbeDoesNotDiscardItsError() throws {
        let body = try Self.stepBody()
        #expect(!body.isEmpty)
        #expect(!body.contains("try?"), """
            `LivenessProbeStep`'s body uses `try?` again — a probe that discards its error \
            cannot say why a tab was marked lost (lost-connection cause, 2026-09-19).
            """)
    }
}
