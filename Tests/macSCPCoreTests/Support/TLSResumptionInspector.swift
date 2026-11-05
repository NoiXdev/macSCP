import Foundation

/// Reads the server's first flight of a TLS handshake off the wire and says
/// whether the handshake RESUMED an earlier session or ran in full.
///
/// **Why this exists at all.** `LoopbackFTPServer` has to enforce what
/// vsftpd's `require_ssl_reuse` enforces: a data connection whose TLS session
/// is not a resumption of the control connection's is refused. Neither TLS
/// stack on offer answers "did this connection resume?" through an API:
///
/// - Network.framework: the metadata accessors of an `NWConnection`'s TLS
///   protocol (`sec_protocol_metadata_*`) hold no such getter, and a probe
///   (docs/superpowers/specs/2026-08-20-backlog-dependencies.md, section
///   "swift-nio-ssl") showed one full handshake and five resumed ones through
///   an `NWListener` indistinguishable in every accessor there is.
/// - swift-nio-ssl: `NIOSSLHandler` exposes `tlsVersion`, `peerCertificate`
///   and the validated chain, and nothing about the session.
///
/// What the wire shows, on the other hand, is unambiguous and needs no
/// library: the server's own handshake messages, which are in the clear up to
/// and including `ServerHello` in both TLS 1.2 and 1.3.
///
/// - **TLS 1.3 (RFC 8446 section 4.2.11):** a server that accepted a PSK says
///   so in its `ServerHello` with the `pre_shared_key` extension (type 41). A
///   full handshake carries `key_share` and no such extension.
/// - **TLS 1.2 (RFC 5246 section 7.3, and RFC 5077 for tickets):** a full
///   handshake continues `ServerHello` with `Certificate` (message type 11).
///   An abbreviated one has no certificate: the next thing the server sends is
///   a `NewSessionTicket` (type 4) or, right away, a `ChangeCipherSpec`
///   record (content type 20).
///
/// **The TLS 1.2 default is fail-open in direction, and has been reasoned
/// through (review of Task 4, 2026-11-05).** Anything after a TLS 1.2
/// `ServerHello` that is not a `Certificate` reads as "resumed". A full
/// handshake the server performs always puts its `Certificate` next, so it
/// cannot be misread that way; the `NewSessionTicket` of RFC 5077 comes in a
/// full handshake only AFTER the `Certificate` and the key exchange, i.e. after
/// this verdict is already fixed. TLS 1.3 cannot reach the default at all: a
/// 1.3 `ServerHello` always carries `supported_versions` selecting 1.3, so it is
/// decided on the 1.3 branch. The one gap is a certificate-less TLS 1.2 suite
/// (anonymous or pre-shared-key), where a full handshake sends no `Certificate`
/// and would read as resumed; swift-nio-ssl does not negotiate those, so it is
/// unmeasured rather than reachable. The consequence of a misread in that
/// direction is a refusal turned into an acceptance by the loopback server's
/// gate, which is why it is written down and not left implicit.
///
/// A `HelloRetryRequest` is also shaped like a `ServerHello`; its fixed
/// random (RFC 8446 section 4.1.3) is recognised and skipped, so a retried
/// handshake is judged on the `ServerHello` that follows it.
///
/// The type is a pure function over bytes. It owns no connection; the tap
/// handler in `LoopbackFTPServer.swift` feeds it what the server writes to
/// the socket.
struct TLSResumptionInspector: Sendable {
    enum Verdict: Equatable, Sendable {
        case undecided
        case fullHandshake
        case resumed
    }

    private(set) var verdict = Verdict.undecided

    /// Bytes received but not yet forming a whole record.
    private var wire: [UInt8] = []
    /// Handshake-record payloads concatenated: a handshake message may span
    /// records, and several may share one.
    private var handshake: [UInt8] = []
    /// A TLS 1.2 `ServerHello` has been seen; what follows decides.
    private var awaitingTLS12Continuation = false

    /// RFC 8446 section 4.1.3: the `random` that marks a `HelloRetryRequest`.
    private static let helloRetryRequestRandom: [UInt8] = [
        0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
        0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
    ]

    mutating func feed(_ bytes: [UInt8]) {
        guard verdict == .undecided else { return }
        wire.append(contentsOf: bytes)
        while verdict == .undecided, wire.count >= 5 {
            let contentType = wire[0]
            let length = Int(wire[3]) << 8 | Int(wire[4])
            guard wire.count >= 5 + length else { return }
            let payload = Array(wire[5..<(5 + length)])
            wire.removeFirst(5 + length)
            switch contentType {
            case 22:
                handshake.append(contentsOf: payload)
                consumeHandshakeMessages()
            case 20:
                // A ChangeCipherSpec straight after a TLS 1.2 ServerHello:
                // no Certificate came, so the session was resumed. In TLS
                // 1.3 it is middlebox-compatibility filler, but by then the
                // ServerHello has already decided.
                if awaitingTLS12Continuation { verdict = .resumed }
            default:
                break
            }
        }
    }

    private mutating func consumeHandshakeMessages() {
        while verdict == .undecided, handshake.count >= 4 {
            let type = handshake[0]
            let length = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
            guard handshake.count >= 4 + length else { return }
            let body = Array(handshake[4..<(4 + length)])
            handshake.removeFirst(4 + length)

            if awaitingTLS12Continuation {
                verdict = type == 11 ? .fullHandshake : .resumed
            } else if type == 2 {
                readServerHello(body)
            }
        }
    }

    private mutating func readServerHello(_ body: [UInt8]) {
        // version(2) random(32) session_id<0..32> cipher(2) compression(1)
        guard body.count >= 35 else { return }
        if Array(body[2..<34]) == Self.helloRetryRequestRandom { return }
        let sessionIDLength = Int(body[34])
        var offset = 35 + sessionIDLength + 2 + 1
        guard body.count >= offset else { return }

        var selectedVersion13 = false
        var hasPreSharedKey = false
        if body.count >= offset + 2 {
            let extensionsLength = Int(body[offset]) << 8 | Int(body[offset + 1])
            offset += 2
            let end = min(body.count, offset + extensionsLength)
            while offset + 4 <= end {
                let extensionType = Int(body[offset]) << 8 | Int(body[offset + 1])
                let extensionLength = Int(body[offset + 2]) << 8 | Int(body[offset + 3])
                let dataStart = offset + 4
                guard dataStart + extensionLength <= end else { break }
                if extensionType == 0x002B, extensionLength == 2,
                    body[dataStart] == 0x03, body[dataStart + 1] == 0x04
                {
                    selectedVersion13 = true
                }
                if extensionType == 0x0029 { hasPreSharedKey = true }
                offset = dataStart + extensionLength
            }
        }

        if selectedVersion13 {
            verdict = hasPreSharedKey ? .resumed : .fullHandshake
        } else {
            awaitingTLS12Continuation = true
        }
    }
}
