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
/// it answers: a stub is handed a list of canned responses and serves them
/// in order, repeating the last one for every further request. `init(response:)`
/// is the one-element case, and it is what a fixed-status test needs. It
/// does keep the request heads it read, so a test can assert on what a
/// server was and was not sent. Requests are served one after another;
/// `Connection: close` in the canned responses below is what keeps that
/// honest.
///
/// The list exists for ONE origin answering a redirect and then the real
/// answer — a same-origin redirect, where both hops necessarily land on
/// this same socket. A cross-origin test uses two stubs instead, and each
/// of those needs only one response.
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

    /// A 200 carrying a well-formed, empty `ListObjectsV2` body, so a
    /// redirect that is followed all the way through makes
    /// `S3FileSystem.connect` SUCCEED — evidence that the hop completed
    /// rather than merely started.
    static let emptyBucketListing: String = {
        let body = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult></ListBucketResult>"#
        return """
            HTTP/1.1 200 OK\r
            Content-Type: application/xml\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
    }()

    let port: Int

    private let listener: Int32
    private let responses: [[UInt8]]
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

    /// Waits until at least `count` requests have been recorded, or the
    /// deadline passes; answers whether the count was reached.
    ///
    /// The accept loop appends to `seenRequests` only after it has written
    /// the response, so a client can finish -- or fail -- before that
    /// append happens. Reading `requests` straight after the operation
    /// under test races that append.
    ///
    /// Waiting cannot weaken an assertion: a request that was never made
    /// never arrives, the deadline runs out, and the assertion fails as it
    /// did before. What it removes is the opposite outcome -- a question
    /// like `sawAuthorizationHeader` answering "no header" for the wrong
    /// reason, because the request carrying one had not been recorded yet.
    func waitForRequests(atLeast count: Int, within seconds: Int = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if requests.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return requests.count >= count
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

    /// The value of one header in a recorded request head, or `nil` if the
    /// head carries no such header. Header names are case-insensitive on
    /// the wire, so the comparison is too; the value is trimmed of the
    /// single space that conventionally follows the colon.
    static func headerValue(_ name: String, in head: String) -> String? {
        let wanted = name.lowercased() + ":"
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix(wanted) {
            return String(line.dropFirst(wanted.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func record(_ request: String) {
        running.lock(); defer { running.unlock() }
        seenRequests.append(request)
    }

    /// The one-response case: every request gets the same answer.
    convenience init(response: String) throws {
        try self.init(responses: [response])
    }

    /// Serves `responses` in order and repeats the last one from then on.
    /// An empty list is a programming error in the test, not a runtime
    /// condition to handle, so it traps.
    init(responses: [String]) throws {
        precondition(!responses.isEmpty, "a stub with no response can answer nothing")
        self.responses = responses.map { Array($0.utf8) }

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
        let canned = self.responses
        DispatchQueue.global().async { [weak self] in
            // Served strictly one at a time, so the counter needs no lock:
            // this loop is the only thing that reads or writes it.
            var served = 0
            while true {
                let client = accept(listenerFD, nil, nil)
                guard client >= 0 else { return }  // the listener was closed
                guard let self, !self.stopped else { close(client); return }
                self.record(Self.serve(client, canned[min(served, canned.count - 1)]))
                served += 1
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
