import Darwin

/// A loopback TCP socket a test owns, for the two ends of a dial: one that
/// listens (accepted) and one whose port was released (refused).
///
/// Shared test support since 2026-09-27, `ConnectionDiagnosticsTests`'
/// own type until then. The App suite needs the refused end as much as the
/// Core suite does: `JumpTwoTabsTests.aRefusedJumpFailsTheNewTabVisiblyAndLeavesTheFirstAlone`
/// dialled a literal `127.0.0.1:1` with the production connector, and a
/// machine with anything listening on port 1 sent that case at the real
/// known-hosts decider, where it hung until the suite's bound
/// (`docs/BACKLOG.md`, "The jump plan's deferred minors: the jump tests").
/// `closedPort()` cannot be that: the kernel names a port that was bound a
/// moment ago, so nothing is listening on it.
///
/// Loopback only, always: `127.0.0.1` is the one address a test here may
/// name, and it is spelled once, here.
public struct LoopbackSocket {
    public let descriptor: Int32
    public let port: Int

    public func close() { Darwin.close(descriptor) }

    /// Binds `127.0.0.1:0`, listens, and reports the port the kernel chose.
    public static func listening() -> LoopbackSocket? {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return LoopbackSocket(
            descriptor: descriptor, port: Int(UInt16(bigEndian: assigned.sin_port)))
    }

    /// A port nothing listens on: bind one, learn its number, give it back.
    public static func closedPort() -> Int? {
        guard let socket = listening() else { return nil }
        socket.close()
        return socket.port
    }
}
