import Foundation
import NIOCore
import NIOSSH

/// Ein vom Server präsentierter Host-Key als reiner Wert (für TOFU-Entscheidungen
/// und den UI-Prompt in Task 3). `publicKeyBase64` ist der OpenSSH-Wire-Blob des
/// Keys (Base64), aus dem der Fingerprint abgeleitet wird.
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

/// Fehler der Host-Key-Prüfung. `mismatch` ist ein harter Stopp ohne Override.
public enum HostKeyError: Error, Equatable, Sendable {
    /// Bekannter Host präsentiert einen ANDEREN Key — harter Stopp, kein Override.
    case mismatch(host: String, expected: String, presented: String)  // Fingerprints
    case rejectedByUser
}

/// Reine, testbare Entscheidungslogik der Host-Key-Prüfung (TOFU).
public enum HostKeyValidation {
    public enum Outcome: Equatable {
        case accept
        case askUser
        case mismatch(expected: String)
    }

    /// Vergleicht den präsentierten Kandidaten mit dem ggf. gemerkten Key.
    /// - unbekannt (`known == nil`) → `.askUser`
    /// - bekannt & identisch → `.accept`
    /// - bekannt & anders → `.mismatch` (der Decider wird NIE gefragt)
    public static func evaluate(candidate: HostKeyCandidate, known: KnownHostKey?) -> Outcome {
        guard let known else { return .askUser }
        if known.fingerprintSHA256 == candidate.fingerprintSHA256 {
            return .accept
        }
        return .mismatch(expected: known.fingerprintSHA256)
    }
}

extension HostKeyCandidate {
    /// Baut einen Kandidaten aus dem vom NIO-SSH-Handshake präsentierten Public Key.
    /// Nutzt ausschließlich die öffentliche OpenSSH-Serialisierung
    /// (`String(openSSHPublicKey:)` → "keytype base64-blob").
    init(host: String, port: Int, publicKey: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: publicKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let keyType = parts.first.map(String.init) ?? "unknown"
        let base64 = parts.count > 1 ? String(parts[1]) : ""
        self.init(host: host, port: port, keyType: keyType, publicKeyBase64: base64)
    }
}

/// Das, was der synchrone NIO-Validator-Hook nach außen meldet, wenn er einen
/// Key nicht still akzeptieren kann. Wird von `CitadelFileSystem.connect`
/// ausgewertet (Decider bzw. harter Mismatch-Stopp).
enum HostKeyProbeResult: Sendable {
    case unknown(HostKeyCandidate)
    case mismatch(host: String, expected: String, presented: String)
}

/// TOFU-Host-Key-Validator als NIO-Delegate (synchroner, Promise-basierter Hook).
///
/// Da der Hook nicht `await`en kann, wird die Entscheidung zweistufig getroffen:
/// bekannte+identische Keys werden hier still akzeptiert; für unbekannte oder
/// abweichende Keys schlägt der Hook fehl und hinterlegt das Ergebnis in `box`.
/// `CitadelFileSystem.connect` liest die Box aus, fragt ggf. den Decider und
/// verbindet nach einem `upsert` mit EINEM Retry erneut (dann bekannt+identisch).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    /// Thread-sicherer Speicher für das Hook-Ergebnis (Hook läuft auf dem Event-Loop).
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
        let known = (try? knownHosts.find(host: host, port: port)) ?? nil

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
