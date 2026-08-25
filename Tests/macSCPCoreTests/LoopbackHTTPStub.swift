import Foundation

/// A minimal HTTP/1.1 server on a loopback port that answers every request
/// with one fixed, caller-supplied response.
///
/// It exists because some WebDAV behaviour lives inside `URLSession` and is
/// unreachable from the stubbed `HTTPTransport` the other WebDAV tests use:
/// an authentication challenge is raised by `URLSession` itself, handed to
/// `WebDAVSessionDelegate`, and answered below the transport seam entirely.
/// Reproducing a rejected password therefore needs something that really
/// speaks HTTP — but not a rig, and never a remote host: this binds
/// 127.0.0.1 on a port the kernel picks, serves for the length of one test,
/// and is torn down with it.
///
/// Deliberately not a general server. Nothing in a request influences what
/// it answers — every one gets the same canned response, which is all a
/// fixed-status test needs. It does keep the request heads it read, so a
/// test can assert on what a server was and was not sent. Requests are
/// served one after another; `Connection: close` in the canned responses
/// below is what keeps that honest.
final class LoopbackHTTPStub: @unchecked Sendable {
    /// A 401 that asks for Basic credentials — so `URLSession` raises an
    /// authentication challenge, and raises it AGAIN when the credential it
    /// then sends is met with the same answer.
    static let basicAuthAlwaysRejects = """
        HTTP/1.1 401 Unauthorized\r
        WWW-Authenticate: Basic realm="macSCP test"\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """

    /// A redirect to another URL, so a test can put a SECOND stub on the
    /// far side of one. `Content-Length: 0` and `Connection: close` keep
    /// this stub's one-request-at-a-time serving honest across the hop.
    static func movedTemporarily(to location: String) -> String {
        """
        HTTP/1.1 302 Found\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    let port: Int

    private let listener: Int32
    private let response: [UInt8]
    private let running = NSLock()
    private var isStopped = false
    private var seenRequests: [String] = []

    /// Every request head this stub has served, in order — the whole thing
    /// up to the blank line, headers included. It is the only way to assert
    /// what a server did NOT receive.
    var requests: [String] {
        running.lock(); defer { running.unlock() }
        return seenRequests
    }

    /// Whether any request carried an `Authorization` header. The question
    /// a redirect test exists to ask.
    var sawAuthorizationHeader: Bool {
        requests.contains { request in
            request.split(separator: "\r\n").contains { line in
                line.lowercased().hasPrefix("authorization:")
            }
        }
    }

    private func record(_ request: String) {
        running.lock(); defer { running.unlock() }
        seenRequests.append(request)
    }

    init(response: String) throws {
        self.response = Array(response.utf8)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        guard fd >= 0 else { throw StubError.socketFailed(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // the kernel picks a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw StubError.bindFailed(errno) }
        guard listen(fd, 8) == 0 else { close(fd); throw StubError.listenFailed(errno) }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); throw StubError.bindFailed(errno) }
        port = Int(UInt16(bigEndian: actual.sin_port))

        let listenerFD = fd
        let canned = self.response
        DispatchQueue.global().async { [weak self] in
            while true {
                let client = accept(listenerFD, nil, nil)
                guard client >= 0 else { return }  // the listener was closed
                guard let self, !self.stopped else { close(client); return }
                self.record(Self.serve(client, canned))
            }
        }
    }

    private var stopped: Bool {
        running.lock(); defer { running.unlock() }
        return isStopped
    }

    /// Closing the listening socket is what breaks the accept loop; it is
    /// idempotent so a `defer` can call it after an early return.
    func stop() {
        running.lock()
        let alreadyStopped = isStopped
        isStopped = true
        running.unlock()
        guard !alreadyStopped else { return }
        close(listener)
    }

    /// Reads the request head, then writes the canned response, and returns
    /// the head it read. The read matters for pacing first of all — a
    /// client whose request is never consumed can see the close as a
    /// connection error instead of as the response it was sent — and the
    /// returned text is what lets a test assert on the headers that
    /// arrived.
    private static func serve(_ client: Int32, _ response: [UInt8]) -> String {
        defer { close(client) }
        var seen = [UInt8]()
        var byte: UInt8 = 0
        while seen.count < 64 * 1024 {
            let count = read(client, &byte, 1)
            guard count == 1 else { break }
            seen.append(byte)
            if seen.count >= 4, Array(seen.suffix(4)) == Array("\r\n\r\n".utf8) { break }
        }
        var written = 0
        response.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let count = write(client, base + written, buffer.count - written)
                guard count > 0 else { return }
                written += count
            }
        }
        return String(decoding: seen, as: UTF8.self)
    }

    enum StubError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}
