import Foundation
import NIOCore
// NIOSSH is provided transitively via Citadel (already in the build graph as
// a checked-out dependency). An explicit package dependency on the
// swift-nio-ssh fork was deliberately NOT added: Auto-Mode blocks the fork
// URL and the module is already available anyway.
import NIOSSH

/// A host key presented by the server, as a plain value (for TOFU decisions
/// and the UI prompt in Task 3). `publicKeyBase64` is the OpenSSH wire blob
/// of the key (Base64), from which the fingerprint is derived.
public struct HostKeyCandidate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKeyBase64: String

    public init(host: String, port: Int, keyType: String, publicKeyBase64: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
    }

    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(ofKeyBlobBase64: publicKeyBase64) ?? "SHA256:?"
    }
}

/// Errors from host-key verification. `mismatch` is a hard stop with no override.
public enum HostKeyError: Error, Equatable, Sendable {
    /// A known host presents a DIFFERENT key — hard stop, no override.
    case mismatch(host: String, expected: String, presented: String)  // fingerprints
    case rejectedByUser
}

/// Pure, testable decision logic for host-key verification (TOFU).
public enum HostKeyValidation {
    public enum Outcome: Equatable {
        case accept
        case askUser
        case mismatch(expected: String)
    }

    /// Compares the presented candidate against the possibly-remembered key.
    /// - unknown (`known == nil`) → `.askUser`
    /// - known & identical → `.accept`
    /// - known & different → `.mismatch` (the decider is NEVER asked)
    public static func evaluate(candidate: HostKeyCandidate, known: KnownHostKey?) -> Outcome {
        guard let known else { return .askUser }
        if known.fingerprintSHA256 == candidate.fingerprintSHA256 {
            return .accept
        }
        return .mismatch(expected: known.fingerprintSHA256)
    }
}

extension HostKeyCandidate {
    /// Builds a candidate from the public key presented by the NIO-SSH
    /// handshake. Uses exclusively the public OpenSSH serialization
    /// (`String(openSSHPublicKey:)` → "keytype base64-blob").
    init(host: String, port: Int, publicKey: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: publicKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let keyType = parts.first.map(String.init) ?? "unknown"
        let base64 = parts.count > 1 ? String(parts[1]) : ""
        self.init(host: host, port: port, keyType: keyType, publicKeyBase64: base64)
    }
}

/// What the synchronous NIO validator hook reports outward when it can't
/// silently accept a key. Evaluated by `CitadelFileSystem.connect` (decider,
/// or hard mismatch stop).
enum HostKeyProbeResult: Sendable {
    case unknown(HostKeyCandidate)
    case mismatch(host: String, expected: String, presented: String)
    /// The known_hosts store wasn't readable (e.g. corrupt JSON). Reported
    /// outward as a hard error — NOT treated as "unknown", so a broken store
    /// doesn't silently lead to re-TOFU/overwrite (fail closed).
    case lookupFailed(reason: String)
}

/// TOFU host-key validator as a NIO delegate (synchronous, Promise-based hook).
///
/// Since the hook can't `await`, the decision is made in two stages: known
/// and identical keys are silently accepted here; for unknown or differing
/// keys the hook fails and stores the result in `box`.
/// `CitadelFileSystem.connect` reads the box, consults the decider if needed,
/// and reconnects after an `upsert` with ONE retry (then known+identical).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    /// Thread-safe storage for the hook's result (the hook runs on the event loop).
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HostKeyProbeResult?

        func set(_ result: HostKeyProbeResult) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }

        var result: HostKeyProbeResult? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private let host: String
    private let port: Int
    private let knownHosts: KnownHostsStore
    let box: Box

    init(host: String, port: Int, knownHosts: KnownHostsStore, box: Box) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
        self.box = box
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let candidate = HostKeyCandidate(host: host, port: port, publicKey: hostKey)
        let known: KnownHostKey?
        do {
            known = try knownHosts.find(host: host, port: port)
        } catch {
            // Store unreadable → fail closed (no downgrade to "unknown").
            box.set(.lookupFailed(reason: String(describing: error)))
            validationCompletePromise.fail(HostKeyError.rejectedByUser)
            return
        }

        switch HostKeyValidation.evaluate(candidate: candidate, known: known) {
        case .accept:
            validationCompletePromise.succeed(())
        case .askUser:
            box.set(.unknown(candidate))
            validationCompletePromise.fail(HostKeyError.rejectedByUser)
        case .mismatch(let expected):
            box.set(.mismatch(host: host, expected: expected,
                              presented: candidate.fingerprintSHA256))
            validationCompletePromise.fail(HostKeyError.mismatch(
                host: host, expected: expected, presented: candidate.fingerprintSHA256))
        }
    }
}
