import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// The probe-cause classifier and the log lines built from it
/// (lost-connection cause, 2026-09-19): a tab marked lost has to say in the
/// diagnostic log whether the probe timed out, the connection closed, or the
/// probe failed some other way — and say it without a secret, a host, a
/// user or a path.
@Suite("Liveness probe failure")
struct LivenessProbeFailureTests {
    // MARK: - The classifier

    @Test func aDeadlineIsATimeout() {
        #expect(LivenessProbeFailure.timeout(seconds: 10).kind == .timeout)
    }

    @Test func aClosedConnectionIsAnErrorThatClosedTheConnection() {
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.connectionFailed(reason: "I/O on closed channel"), probedPath: "/")
        guard case .error(let typeName, _, let closed) = failure else {
            Issue.record("expected .error, got \(failure)")
            return
        }
        #expect(typeName == "RemoteFSError")
        #expect(closed)
        #expect(failure.kind == .connectionClosed)
    }

    /// An error that reached the probe without `mapSFTPError` in front of it.
    @Test func aRawClosedChannelIsAlsoAClosedConnection() {
        let failure = LivenessProbeFailure.classify(ChannelError.ioOnClosedChannel, probedPath: "/")
        guard case .error(let typeName, _, true) = failure else {
            Issue.record("expected a closed-connection .error, got \(failure)")
            return
        }
        #expect(typeName == "ChannelError")
        #expect(failure.kind == .connectionClosed)
    }

    @Test func anErrorThatLeavesTheConnectionStandingIsOther() {
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.permissionDenied(path: "/srv"), probedPath: "/srv")
        guard case .error(_, _, false) = failure else {
            Issue.record("expected a non-closing .error, got \(failure)")
            return
        }
        #expect(failure.kind == .other)
    }

    @Test func aCancellationIsACancellation() {
        let failure = LivenessProbeFailure.classify(CancellationError(), probedPath: "/")
        #expect(failure == .cancelled)
        #expect(failure.kind == .other)
    }

    /// The reason is `DialSupport.reason(for:)`'s sentence, not the error's
    /// own description — a `RemoteFSError.protocolError` carries free text,
    /// and that sentence drops it.
    @Test func theReasonIsTheFixedSentence() {
        let error = RemoteFSError.protocolError(reason: "whatever the server said")
        let failure = LivenessProbeFailure.classify(error, probedPath: "/")
        guard case .error(_, let reason, _) = failure else {
            Issue.record("expected .error, got \(failure)")
            return
        }
        #expect(reason == DialSupport.reason(for: error))
    }

    // MARK: - The log lines

    private static let tab = UUID()

    @Test(arguments: [
        (LivenessProbeFailure.timeout(seconds: 10), "cause=timeout", "kind=timeout"),
        (.error(typeName: "RemoteFSError", reason: "r", closedConnection: true), "cause=error", "kind=closed"),
        (.error(typeName: "RemoteFSError", reason: "r", closedConnection: false), "cause=error", "kind=other"),
        (.cancelled, "cause=cancelled", "kind=other"),
    ])
    func everyProbeLineNamesItsCauseAndTab(failure: LivenessProbeFailure, cause: String, kind: String) {
        let line = LivenessLogLines.probeFailed(tab: Self.tab, failure: failure)
        #expect(line.contains(cause))
        #expect(line.contains(kind))
        #expect(line.contains("tab=\(Self.tab)"))
    }

    @Test func anErrorLineNamesTheTypeAndTheSentence() {
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.connectionFailed(reason: "x"), probedPath: "/")
        let line = LivenessLogLines.probeFailed(tab: Self.tab, failure: failure)
        #expect(line.contains("type=RemoteFSError"))
        #expect(line.contains("detail=\(DialSupport.reason(for: RemoteFSError.connectionFailed(reason: "x")))"))
    }

    @Test func theLostLineCarriesTheLastCauseInFull() {
        let failure = LivenessProbeFailure.timeout(seconds: 7)
        let line = LivenessLogLines.connectionLost(tab: Self.tab, lastFailure: failure)
        #expect(line.contains("connection lost"))
        #expect(line.contains("cause=timeout"))
        #expect(line.contains("after=7s"))
        #expect(line.contains("tab=\(Self.tab)"))
        #expect(LivenessLogLines.connectionLost(tab: Self.tab, lastFailure: nil).contains("cause=unknown"))
    }

    @Test(arguments: [
        (TransportHop.target, TransportCloseInitiator.peerOrNetwork, "hop=target by=peer-or-network"),
        (.jump, .app, "hop=jump by=app"),
    ])
    func aCloseLineNamesTheHopAndTheSide(
        hop: TransportHop, initiator: TransportCloseInitiator, expected: String
    ) {
        let line = LivenessLogLines.transportClosed(
            tab: Self.tab, event: TransportCloseEvent(hop: hop, initiator: initiator))
        #expect(line.contains(expected))
        #expect(line.contains("tab=\(Self.tab)"))
    }

    // MARK: - No secret, no user, no path
    //
    // Every value that must not leak is a named constant, and each check
    // computes its `Bool` before the expectation: `#expect` prints the
    // source text of what it checks, so a literal in the expectation would
    // leak through the failure message the check exists to prevent
    // (CLAUDE.md, "A value a test must not leak has two exits").

    private static let secret = "s3cr3t-Pa55-Liveness"
    private static let account = "maintaineraccount"
    private static var home: String { "/home/\(account)" }

    /// A foreign error whose own text carries a URL with a credential in it.
    @Test func aCredentialInAForeignErrorsTextIsNotLogged() {
        let error = NSError(
            domain: "Probe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "failed talking to sftp://admin:\(Self.secret)@bastion.example"])
        let line = LivenessLogLines.probeFailed(
            tab: Self.tab, failure: LivenessProbeFailure.classify(error, probedPath: "/"))
        let leaks = line.contains(Self.secret)
        #expect(leaks == false)
        #expect(line.contains("cause=error"))
    }

    /// Free text a backend composed out of what the user typed.
    @Test func freeTextInARemoteErrorIsNotLogged() {
        for error in [
            RemoteFSError.connectionFailed(reason: "https://KEY:\(Self.secret)@s3.example"),
            RemoteFSError.protocolError(reason: Self.secret),
        ] {
            let line = LivenessLogLines.probeFailed(
                tab: Self.tab, failure: LivenessProbeFailure.classify(error, probedPath: Self.home))
            let leaks = line.contains(Self.secret)
            #expect(leaks == false)
        }
    }

    /// `DialSupport.reason(for:)` prints the path for these two; the probed
    /// path is the home, and the home names the account.
    @Test func theProbedHomeIsNotLogged() {
        for error in [
            RemoteFSError.notFound(path: Self.home),
            RemoteFSError.permissionDenied(path: Self.home),
        ] {
            let line = LivenessLogLines.probeFailed(
                tab: Self.tab, failure: LivenessProbeFailure.classify(error, probedPath: Self.home))
            let namesTheAccount = line.contains(Self.account)
            #expect(namesTheAccount == false)
            #expect(line.contains("<home>"))
        }
    }
}

/// `TransportCloseMonitor`: the state behind a connection's close reports.
@Suite("Transport close monitor")
struct TransportCloseMonitorTests {
    private final class Recorder: Sendable {
        private let events = MutexBox<[TransportCloseEvent]>([])
        var recorded: [TransportCloseEvent] { events.value }
        func record(_ event: TransportCloseEvent) { events.mutate { $0.append(event) } }
    }

    @Test func aCloseNobodyAskedForIsThePeersOrTheNetworks() {
        let monitor = TransportCloseMonitor()
        let recorder = Recorder()
        monitor.setHandler(recorder.record)
        monitor.closed(.target)
        #expect(recorder.recorded == [TransportCloseEvent(hop: .target, initiator: .peerOrNetwork)])
    }

    @Test func aCloseAfterDisconnectWasCalledIsTheApps() {
        let monitor = TransportCloseMonitor()
        let recorder = Recorder()
        monitor.setHandler(recorder.record)
        monitor.markCloseRequested()
        monitor.closed(.target)
        monitor.closed(.jump)
        #expect(recorder.recorded == [
            TransportCloseEvent(hop: .target, initiator: .app),
            TransportCloseEvent(hop: .jump, initiator: .app),
        ])
    }

    /// A handler installed after the close still hears about it — the App
    /// installs its handler after the connect returned.
    @Test func aCloseBeforeTheHandlerIsDeliveredWhenItArrives() {
        let monitor = TransportCloseMonitor()
        monitor.closed(.jump)
        let recorder = Recorder()
        monitor.setHandler(recorder.record)
        #expect(recorder.recorded == [TransportCloseEvent(hop: .jump, initiator: .peerOrNetwork)])
    }

    /// The close hook and the "already closed" check can both see one close.
    @Test func eachHopIsReportedOnce() {
        let monitor = TransportCloseMonitor()
        let recorder = Recorder()
        monitor.setHandler(recorder.record)
        monitor.closed(.target)
        monitor.closed(.target)
        #expect(recorder.recorded.count == 1)
    }
}

/// A minimal lock-protected value for the recorder above.
private final class MutexBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
