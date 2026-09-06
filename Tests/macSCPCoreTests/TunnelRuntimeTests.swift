import Foundation
import MacSCPTestSupport
import NIOCore
import Testing

@testable import macSCPCore

/// `EndReportingTransport` — the decorator that closes Task 4's hand-off
/// ("a forward that dies AFTER `onOpen` reports to nobody").
///
/// Four cases — counted here, one per `@Test` below — and the split between
/// them is the whole type: an ending after the server confirmed the forward
/// IS a loss; an ending before it is the start's own failure, which
/// `RemoteForward.start` already throws; and a cancellation is how `stop()`
/// ends a forward normally, so it is not an ending at all — whether the
/// transport signals that by throwing `CancellationError` or, as Citadel's
/// own wrapper does, by simply returning.
///
/// Written after a mutation probe on the cancellation gate came back GREEN
/// (2026-09-06): nothing reached this type, because a `.remote` runtime is
/// otherwise only built over a live SSH connection.
@Suite("Tunnel runtime", .timeLimit(.minutes(1)))
struct TunnelRuntimeTests {

    @Test func aForwardThatEndsAfterTheServerConfirmedItIsReported() async throws {
        let endings = EndingRecorder()
        let connection = TunnelFakeForwardingConnection(behaviour: .openThenReturn)
        let transport = EndReportingTransport(
            wrapped: connection, onEnded: { endings.record() })

        try await transport.withRemotePortForward(
            bind: "127.0.0.1", port: 45_000, onOpen: { _ in }, handleChannel: { _ in })

        #expect(endings.count == 1)
    }

    /// A transport that fails before naming a port has failed the START.
    /// `RemoteForward.start` throws that error to its caller, and reporting
    /// an ending as well would drive a reconnect for a forward that never
    /// existed.
    @Test func aForwardThatFailsBeforeTheServerAnsweredIsNotAnEnding() async throws {
        let endings = EndingRecorder()
        let connection = TunnelFakeForwardingConnection(behaviour: .throwBeforeOpen)
        let transport = EndReportingTransport(
            wrapped: connection, onEnded: { endings.record() })

        var raised = false
        do {
            try await transport.withRemotePortForward(
                bind: "127.0.0.1", port: 45_000, onOpen: { _ in }, handleChannel: { _ in })
        } catch {
            raised = true
        }

        #expect(raised)
        #expect(endings.count == 0)
    }

    /// The `CancellationError` arm: `RemoteForward.stop()` cancels the task
    /// carrying the forward, which is how `cancel-tcpip-forward` gets sent.
    @Test func aCancelledForwardIsNotAnEnding() async throws {
        let endings = EndingRecorder()
        let connection = TunnelFakeForwardingConnection(behaviour: .openThenThrowCancellation)
        let transport = EndReportingTransport(
            wrapped: connection, onEnded: { endings.record() })

        var raised = false
        do {
            try await transport.withRemotePortForward(
                bind: "127.0.0.1", port: 45_000, onOpen: { _ in }, handleChannel: { _ in })
        } catch is CancellationError {
            raised = true
        }

        #expect(raised)
        #expect(endings.count == 0)
    }

    /// The other half of the cancellation gate, and the one a `catch` cannot
    /// cover: a transport that RETURNS normally once its task is cancelled.
    /// Citadel's own wrapper is this shape — its sleep ends on cancellation
    /// and it returns after sending `cancel-tcpip-forward` — so without the
    /// `!Task.isCancelled` check every `stop()` of a remote forward would
    /// report a loss and start a reconnect the user just asked to end.
    @Test func aForwardThatReturnsAfterCancellationIsNotAnEnding() async throws {
        let endings = EndingRecorder()
        let opened = EndingRecorder()
        let connection = TunnelFakeForwardingConnection(behaviour: .openThenReturnOnCancellation)
        let transport = EndReportingTransport(
            wrapped: connection, onEnded: { endings.record() })

        let carrying = Task {
            try await transport.withRemotePortForward(
                bind: "127.0.0.1", port: 45_000, onOpen: { _ in opened.record() },
                handleChannel: { _ in })
        }
        try await pollUntil("the fake transport to name its port") { opened.count == 1 }
        carrying.cancel()
        _ = try? await carrying.value

        #expect(endings.count == 0)
    }
}

private final class EndingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record() {
        lock.withLock { recorded += 1 }
    }
}

/// A connection whose `withRemotePortForward` does exactly one scripted
/// thing — the four shapes the decorator has to tell apart.
private struct TunnelFakeForwardingConnection: TunnelSSHConnection {
    enum Behaviour: Sendable {
        case openThenReturn
        case openThenThrowCancellation
        case throwBeforeOpen
        case openThenReturnOnCancellation
    }

    let behaviour: Behaviour

    func onDisconnect(_ handler: @escaping @Sendable () -> Void) {}

    func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        throw TunnelFailure.channelOpenFailed(reason: "the fake connection opens no channels")
    }

    func withRemotePortForward(
        bind: String, port: Int, onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        switch behaviour {
        case .throwBeforeOpen:
            throw TunnelFailure.bindFailed(reason: "the server refused the forwarding request")
        case .openThenReturn:
            onOpen(port)
        case .openThenThrowCancellation:
            onOpen(port)
            throw CancellationError()
        case .openThenReturnOnCancellation:
            onOpen(port)
            // Citadel's own shape: park until cancelled, then RETURN — no
            // throw. Deliberately NOT `pollUntil`, which rethrows the
            // cancellation it is waiting for; `try?` swallows the sleep's
            // own throw so the loop can exit by returning, which is the
            // whole point of this arm. No deadline of its own: the suite's
            // `.timeLimit` is what ends a wait that cannot be satisfied.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func disconnect() async {}
}
