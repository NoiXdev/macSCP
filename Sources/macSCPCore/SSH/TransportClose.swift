import Synchronization

/// Which SSH connection of a session closed (lost-connection cause, 2026-09-19).
///
/// A session through a jump host holds two: the jump connection, and the
/// target connection that runs as a forwarded channel inside it. Telling
/// them apart is the whole point — a jump that closed takes the target with
/// it, a target that closed on its own leaves the jump standing.
public enum TransportHop: String, Sendable, Equatable {
    case target
    case jump
}

/// Who closed an SSH connection, as far as macSCP can know it.
///
/// Two cases, not three: macSCP knows exactly when IT asked for the close
/// (`CitadelFileSystem.disconnect()`), and nothing else. A server that sent
/// a disconnect, a TCP reset from a middlebox, a network that went away —
/// the transport this project connects through reports all of them the same
/// way, as a closed channel with no reason attached (Citadel's
/// `SSHClient.onDisconnect` takes no argument, and the channel it watches is
/// not public), so this type does not pretend to separate them.
public enum TransportCloseInitiator: String, Sendable, Equatable {
    /// `disconnect()` had been called before the close arrived.
    case app
    /// The close arrived without macSCP asking for it.
    case peerOrNetwork = "peer-or-network"
}

/// One SSH connection of a session closed.
public struct TransportCloseEvent: Sendable, Equatable {
    public let hop: TransportHop
    public let initiator: TransportCloseInitiator

    public init(hop: TransportHop, initiator: TransportCloseInitiator) {
        self.hop = hop
        self.initiator = initiator
    }
}

/// A connection that can say when its transport closes — adopted by
/// `CitadelFileSystem`; the other backends have no long-lived transport to
/// report on.
///
/// Observation only. Registering a handler neither owns nor extends the
/// connection's lifetime: the handler is held by the connection's own close
/// hooks, never the other way round, and the UI's teardown order is
/// unchanged by it.
public protocol TransportCloseReporting: Sendable {
    /// Installs `handler`, replacing any handler installed before. Closes
    /// that happened before the call are delivered to it at once, so a
    /// handler installed after the connect returns still hears about a
    /// connection that closed in between. Each hop is reported at most once.
    func onTransportClose(_ handler: @escaping @Sendable (TransportCloseEvent) -> Void)
}

/// The state behind `TransportCloseReporting` for one connection: whether
/// macSCP asked for the close, which hops have already been reported, and
/// the handler or the closes still waiting for one.
///
/// Its own type, rather than fields on `CitadelFileSystem`, so the close
/// hooks the connection installs on its SSH clients can capture THIS and
/// nothing else. Capturing the file system would put it inside a closure
/// the SSH client holds, and the file system holds the client — a cycle
/// that would keep a closed connection alive.
final class TransportCloseMonitor: Sendable {
    private struct State {
        var closeRequested = false
        var reported: Set<TransportHop> = []
        var pending: [TransportCloseEvent] = []
        var handler: (@Sendable (TransportCloseEvent) -> Void)?
    }

    private let state = Mutex(State())

    init() {}

    /// Called by `disconnect()` BEFORE it closes anything, so every close
    /// that follows reads as `.app`.
    func markCloseRequested() {
        state.withLock { $0.closeRequested = true }
    }

    /// A hop's transport closed. Reports it once; a second report of the
    /// same hop — the close hook and the "already closed at install" check
    /// can both see one close — is dropped.
    func closed(_ hop: TransportHop) {
        let delivery: (handler: @Sendable (TransportCloseEvent) -> Void, event: TransportCloseEvent)? =
            state.withLock { s in
                guard !s.reported.contains(hop) else { return nil }
                s.reported.insert(hop)
                let event = TransportCloseEvent(
                    hop: hop, initiator: s.closeRequested ? .app : .peerOrNetwork)
                guard let handler = s.handler else {
                    s.pending.append(event)
                    return nil
                }
                return (handler, event)
            }
        // Outside the lock: a handler that logged, or called back into this
        // monitor, must not run inside the critical section.
        if let delivery { delivery.handler(delivery.event) }
    }

    /// Installs the handler and hands it every close it missed.
    func setHandler(_ handler: @escaping @Sendable (TransportCloseEvent) -> Void) {
        let missed: [TransportCloseEvent] = state.withLock { s in
            s.handler = handler
            let missed = s.pending
            s.pending = []
            return missed
        }
        for event in missed { handler(event) }
    }
}
