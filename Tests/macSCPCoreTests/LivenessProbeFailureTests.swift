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
            RemoteFSError.connectionFailed(reason: "I/O on closed channel"))
        guard case .error(let typeName, let closed) = failure else {
            Issue.record("expected .error, got \(failure)")
            return
        }
        #expect(typeName == "RemoteFSError")
        #expect(closed)
        #expect(failure.kind == .connectionClosed)
    }

    /// An error that reached the probe without `mapSFTPError` in front of it.
    @Test func aRawClosedChannelIsAlsoAClosedConnection() {
        let failure = LivenessProbeFailure.classify(ChannelError.ioOnClosedChannel)
        guard case .error(let typeName, true) = failure else {
            Issue.record("expected a closed-connection .error, got \(failure)")
            return
        }
        #expect(typeName == "ChannelError")
        #expect(failure.kind == .connectionClosed)
    }

    @Test func anErrorThatLeavesTheConnectionStandingIsOther() {
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.permissionDenied(path: "/srv"))
        guard case .error(_, false) = failure else {
            Issue.record("expected a non-closing .error, got \(failure)")
            return
        }
        #expect(failure.kind == .other)
    }

    @Test func aCancellationIsACancellation() {
        let failure = LivenessProbeFailure.classify(CancellationError())
        #expect(failure == .cancelled)
        #expect(failure.kind == .other)
    }

    /// The classified value itself carries no sentence: an error's free
    /// text is not in it, so nothing downstream can print it.
    @Test func theClassifiedValueCarriesNoSentence() {
        let serversOwnText = "whatever the server said"
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.protocolError(reason: serversOwnText))
        let carriesTheServersText = String(describing: failure).contains(serversOwnText)
        #expect(carriesTheServersText == false)
        #expect(failure == .error(typeName: "RemoteFSError", closedConnection: false))
    }

    // MARK: - The log lines

    private static let tab = UUID()

    @Test(arguments: [
        (LivenessProbeFailure.timeout(seconds: 10), "cause=timeout", "kind=timeout"),
        (.error(typeName: "RemoteFSError", closedConnection: true), "cause=error", "kind=closed"),
        (.error(typeName: "RemoteFSError", closedConnection: false), "cause=error", "kind=other"),
        (.cancelled, "cause=cancelled", "kind=other"),
    ])
    func everyProbeLineNamesItsCauseAndTab(failure: LivenessProbeFailure, cause: String, kind: String) {
        let line = LivenessLogLines.probeFailed(tab: Self.tab, failure: failure)
        #expect(line.contains(cause))
        #expect(line.contains(kind))
        #expect(line.contains("tab=\(Self.tab)"))
    }

    @Test func anErrorLineNamesTheType() {
        let failure = LivenessProbeFailure.classify(
            RemoteFSError.connectionFailed(reason: "x"))
        let line = LivenessLogLines.probeFailed(tab: Self.tab, failure: failure)
        #expect(line.contains("type=RemoteFSError"))
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

    // MARK: - A closed set of causes, and no sentence from an error
    //
    // Fix round 1, item 1: the line carries the cause, the kind, the
    // deadline's seconds and the error's Swift type name — nothing that an
    // error, a server or a form could have composed. Every value that must
    // not leak is a named constant, and each check computes its `Bool`
    // before the expectation: `#expect` prints the source text of what it
    // checks, so a literal in the expectation would leak through the
    // failure message the check exists to prevent (CLAUDE.md, "A value a
    // test must not leak has two exits").

    private static let secret = "s3cr3t-Pa55-Liveness"
    private static let account = "maintaineraccount"
    private static let host = "bastion.invalid"
    private static let serverText = "the server said something long"
    private static var home: String { "/home/\(account)" }

    /// A foreign error whose own text carries a host and a credential.
    @Test func nothingAForeignErrorSaysReachesTheLine() {
        let error = NSError(
            domain: "Probe", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "failed talking to sftp://admin:\(Self.secret)@\(Self.host)"
            ])
        let line = LivenessLogLines.probeFailed(
            tab: Self.tab, failure: LivenessProbeFailure.classify(error))
        let carriesTheSecret = line.contains(Self.secret)
        let carriesTheHost = line.contains(Self.host)
        #expect(carriesTheSecret == false)
        #expect(carriesTheHost == false)
        #expect(line.contains("cause=error"))
        #expect(line.contains("type=NSError"))
    }

    /// Free text a backend composed out of what the user typed, and free
    /// text a server sent.
    @Test func noFreeTextFromARemoteErrorReachesTheLine() {
        for error in [
            RemoteFSError.connectionFailed(reason: "https://KEY:\(Self.secret)@s3.example"),
            RemoteFSError.protocolError(reason: Self.serverText),
        ] {
            let line = LivenessLogLines.probeFailed(
                tab: Self.tab, failure: LivenessProbeFailure.classify(error))
            let carriesTheSecret = line.contains(Self.secret)
            let carriesTheServersText = line.contains(Self.serverText)
            #expect(carriesTheSecret == false)
            #expect(carriesTheServersText == false)
        }
    }

    /// `DialSupport.reason(for:)` prints the path for these two. The line
    /// does not go through it at all, so neither the probed home nor any
    /// other path can reach it.
    @Test func noPathReachesTheLine() {
        for error in [
            RemoteFSError.notFound(path: Self.home),
            RemoteFSError.permissionDenied(path: "/srv/\(Self.account)"),
        ] {
            let line = LivenessLogLines.probeFailed(
                tab: Self.tab, failure: LivenessProbeFailure.classify(error))
            let namesTheAccount = line.contains(Self.account)
            let namesAPath = line.contains("/")
            #expect(namesTheAccount == false)
            #expect(namesAPath == false)
        }
    }

    /// The whole line, spelled out: a reader knows exactly what a probe
    /// line can say, because there is nothing in it that is not from this
    /// list.
    @Test func theLineIsTheClosedSetAndNothingElse() {
        let uuid = UUID()
        #expect(
            LivenessLogLines.probeFailed(tab: uuid, failure: .timeout(seconds: 10))
                == "liveness probe failed tab=\(uuid) cause=timeout kind=timeout after=10s")
        #expect(
            LivenessLogLines.probeFailed(tab: uuid, failure: .cancelled)
                == "liveness probe failed tab=\(uuid) cause=cancelled kind=other")
        #expect(
            LivenessLogLines.probeFailed(
                tab: uuid, failure: .error(typeName: "RemoteFSError", closedConnection: true))
                == "liveness probe failed tab=\(uuid) cause=error kind=closed type=RemoteFSError")
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

    /// The observation ends with the thing observed (fix round 1, review
    /// Minor 8): once the App stops reporting, a close that arrives late —
    /// from a client whose channel had not finished closing — writes
    /// nothing for a session that is gone.
    @Test func aCloseAfterReportingStoppedIsNotDelivered() {
        let monitor = TransportCloseMonitor()
        let recorder = Recorder()
        monitor.setHandler(recorder.record)
        monitor.stopReporting()
        monitor.closed(.target)
        #expect(recorder.recorded.isEmpty)
    }

    /// And nothing is kept for a handler that never comes back either —
    /// neither a close buffered before the stop, nor one that arrives after
    /// it. A tab that reconnects gets a NEW connection with a monitor of its
    /// own; the old one is over, and "over" has to mean it for both.
    @Test func nothingIsKeptForAHandlerAfterReportingStopped() {
        let buffered = TransportCloseMonitor()
        buffered.closed(.target)
        buffered.stopReporting()
        let afterBuffered = Recorder()
        buffered.setHandler(afterBuffered.record)
        #expect(afterBuffered.recorded.isEmpty)

        let late = TransportCloseMonitor()
        late.stopReporting()
        late.closed(.jump)
        let afterLate = Recorder()
        late.setHandler(afterLate.record)
        #expect(afterLate.recorded.isEmpty)
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
