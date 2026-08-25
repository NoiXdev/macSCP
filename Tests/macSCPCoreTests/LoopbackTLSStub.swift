import Foundation
import Network
import Security

/// `LoopbackHTTPStub`'s TLS twin: an HTTPS server on a loopback port,
/// presenting a self-signed certificate the system does not trust, so a
/// request to it raises a real server-trust challenge.
///
/// It exists because the certificate arm of `WebDAVSessionDelegate` is
/// reachable only from a genuine TLS handshake — `URLSession` builds the
/// `SecTrust` itself and there is no supported way to hand it one. Proving
/// what a redirect can make that arm do therefore needs a server that
/// really speaks TLS.
///
/// Nothing here touches a keychain. The key pair and certificate are
/// generated at runtime by `openssl` into a temporary directory that is
/// removed as soon as the bytes have been read, and the PKCS#12 is imported
/// with `kSecImportToMemoryOnly` — which, per Security's own header, keeps
/// the items in process memory and does not use the keychain at all
/// (macOS 15 and later; this package's minimum). No key material is ever
/// written into the repository.
final class LoopbackTLSStub: @unchecked Sendable {
    let port: Int

    private let listener: NWListener
    private let recorder = Recorder()

    /// Every request head this stub has served, in order. Same contract as
    /// the plaintext stub's, and the same reason: it is the only way to
    /// assert what a server did NOT receive.
    var requests: [String] { recorder.requests }

    var sawAuthorizationHeader: Bool {
        requests.contains { request in
            request.split(separator: "\r\n").contains { line in
                line.lowercased().hasPrefix("authorization:")
            }
        }
    }

    init(response: String) throws {
        let identity = try Self.makeEphemeralIdentity()

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        // Bound to loopback explicitly, on a port the kernel picks.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure.value = error; ready.signal()
            default: break
            }
        }
        // Captures the recorder, never `self`: the handler is installed
        // before `port` is assigned, so `self` is not yet whole here.
        let canned = Data(response.utf8)
        let recorder = self.recorder
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, _, _ in
                    if let data { recorder.record(String(decoding: data, as: UTF8.self)) }
                    connection.send(content: canned, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())

        guard ready.wait(timeout: .now() + 20) == .success else {
            listener.cancel()
            throw StubError.listenerNeverBecameReady
        }
        if let error = failure.value {
            listener.cancel()
            throw error
        }
        guard let assigned = listener.port else {
            listener.cancel()
            throw StubError.listenerNeverBecameReady
        }
        port = Int(assigned.rawValue)
    }

    /// Idempotent, so a `defer` can call it after an early return.
    func stop() {
        listener.cancel()
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
        func record(_ request: String) {
            lock.lock(); defer { lock.unlock() }
            seen.append(request)
        }
    }

    /// Generates a throwaway key pair and self-signed certificate and
    /// returns them as an identity held only in memory.
    private static func makeEphemeralIdentity() throws -> sec_identity_t {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tls-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyPath = directory.appendingPathComponent("key.pem").path(percentEncoded: false)
        let certPath = directory.appendingPathComponent("cert.pem").path(percentEncoded: false)
        let bundlePath = directory.appendingPathComponent("bundle.p12").path(percentEncoded: false)
        let passphrase = UUID().uuidString

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath, "-out", certPath,
            "-days", "1", "-subj", "/CN=127.0.0.1",
        ])
        try runOpenSSL([
            "pkcs12", "-export", "-inkey", keyPath, "-in", certPath,
            "-out", bundlePath, "-passout", "pass:\(passphrase)", "-name", "macscp-test",
        ])

        let bundle = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
        var imported: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            // Keeps the identity in process memory; the keychain is not
            // consulted or written. Without this, macOS would import into
            // the user's default keychain.
            kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
        ]
        let status = SecPKCS12Import(bundle as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let identityItem = items.first?[kSecImportItemIdentity as String]
        else { throw StubError.identityImportFailed(status) }
        // `SecPKCS12Import` hands the identity back as a `CFTypeRef` that is
        // a `SecIdentity`; the cast is the documented way to recover it.
        let secIdentity = identityItem as! SecIdentity  // swiftlint:disable:this force_cast
        guard let identity = sec_identity_create(secIdentity) else {
            throw StubError.identityImportFailed(errSecInvalidValue)
        }
        return identity
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StubError.opensslFailed(arguments.first ?? "?", process.terminationStatus)
        }
    }

    enum StubError: Error {
        case listenerNeverBecameReady
        case identityImportFailed(OSStatus)
        case opensslFailed(String, Int32)
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var value: Error? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
}
