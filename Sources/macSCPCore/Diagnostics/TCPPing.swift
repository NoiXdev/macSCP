import Darwin
import Foundation

/// What one TCP connection attempt found at an address.
///
/// `refused` is a SUCCESSFUL measurement: something on the other end answered
/// the SYN with a RST, which tells the user the host is up and the port is
/// not. `timedOut` is the one that says nothing came back at all.
enum TCPPingOutcome: Sendable, Equatable {
    case accepted(Duration)
    case refused(Duration)
    case timedOut
    /// `strerror` for whatever the kernel said instead — no route, no
    /// permission, address family unsupported.
    case failed(String)
}

/// One non-blocking TCP connect per address, bounded by its own deadline.
///
/// Non-blocking plus `poll` rather than a plain `connect`: Darwin's own
/// connect timeout is 75 seconds, and a step that waits that long has stopped
/// being a diagnosis. The socket is closed in a `defer` on every path.
enum TCPPing {
    static func probe(address: ResolvedAddress, timeout: Duration) async -> TCPPingOutcome {
        await BlockingProbe.run(label: "dev.noidee.macscp.diagnostics.tcp", timeout: timeout) {
            attempt(address: address, timeout: timeout)
        } ?? .timedOut
    }

    /// Every address in turn, on ONE queue hop and against ONE shared
    /// deadline, so a host with four addresses cannot spend four times the
    /// step's budget. Addresses left over when the budget runs out are
    /// reported as timed out rather than silently dropped — a row that lists
    /// fewer addresses than the resolve step found reads as a resolver
    /// disagreement.
    static func probeAll(
        addresses: [ResolvedAddress], timeout: Duration
    ) async -> [(address: ResolvedAddress, outcome: TCPPingOutcome)] {
        await BlockingProbe.run(label: "dev.noidee.macscp.diagnostics.tcp", timeout: timeout) {
            var results: [(address: ResolvedAddress, outcome: TCPPingOutcome)] = []
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            for address in addresses {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    results.append((address, .timedOut))
                    continue
                }
                results.append((address, attempt(address: address, timeout: remaining)))
            }
            return results
        } ?? addresses.map { ($0, .timedOut) }
    }

    /// Blocking. Only ever called on `BlockingProbe`'s private queue.
    private static func attempt(address: ResolvedAddress, timeout: Duration) -> TCPPingOutcome {
        address.socketAddress.withSockaddr { sockaddrPointer, length in
            let descriptor = socket(Int32(sockaddrPointer.pointee.sa_family), SOCK_STREAM, IPPROTO_TCP)
            guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
            defer { close(descriptor) }

            let existingFlags = fcntl(descriptor, F_GETFL, 0)
            guard existingFlags >= 0, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) >= 0
            else { return .failed(String(cString: strerror(errno))) }

            let clock = ContinuousClock()
            let started = clock.now

            if connect(descriptor, sockaddrPointer, length) == 0 {
                // Loopback answers inside the call itself.
                return .accepted(started.duration(to: clock.now))
            }
            let connectError = errno
            guard connectError == EINPROGRESS else {
                return classify(connectError, elapsed: started.duration(to: clock.now))
            }

            var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(1, min(timeout.milliseconds.rounded(), 2_000_000_000)))
            let ready = poll(&watched, 1, milliseconds)
            let elapsed = started.duration(to: clock.now)
            if ready == 0 { return .timedOut }
            guard ready > 0 else { return .failed(String(cString: strerror(errno))) }

            // POLLOUT alone does not mean the connect succeeded: a refused
            // connect is also "writable", and the verdict is in `SO_ERROR`.
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0
            else { return .failed(String(cString: strerror(errno))) }
            if socketError == 0 { return .accepted(elapsed) }
            return classify(socketError, elapsed: elapsed)
        }
    }

    private static func classify(_ code: Int32, elapsed: Duration) -> TCPPingOutcome {
        switch code {
        case ECONNREFUSED: return .refused(elapsed)
        case ETIMEDOUT: return .timedOut
        default: return .failed(String(cString: strerror(code)))
        }
    }
}

extension TCPPingOutcome {
    /// The word one address contributes to the TCP step's detail line.
    var label: String {
        switch self {
        case .accepted: return "accepted"
        case .refused: return "refused"
        case .timedOut: return "timed out"
        case .failed(let reason): return reason
        }
    }

    var elapsed: Duration? {
        switch self {
        case .accepted(let duration), .refused(let duration): return duration
        case .timedOut, .failed: return nil
        }
    }
}
