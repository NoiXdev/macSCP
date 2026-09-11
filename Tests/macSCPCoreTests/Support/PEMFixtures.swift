import Crypto
import Foundation
import SwiftASN1
import Testing
import _CryptoExtras
import macSCPCore

/// Runtime PEM key files for the decoder, loader and converter tests. Every
/// file is written into a fresh temporary directory the caller removes;
/// nothing here is checked in. The passphrase is the caller's constant and
/// reaches exactly one place: `ssh-keygen -N` / `openssl -passout pass:`.
enum PEMFixtures {
    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-pem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    enum Format: String, Sendable { case pem = "PEM", pkcs8 = "PKCS8" }

    struct Shape: Sendable, CustomStringConvertible {
        let type: String; let bits: Int; let format: Format
        var description: String { "\(type)-\(bits)-\(format.rawValue)" }
        /// Four key shapes × two ssh-keygen output formats — eight, counted.
        static let all: [Shape] = [("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)]
            .flatMap { t, b in [Format.pem, .pkcs8].map { Shape(type: t, bits: b, format: $0) } }
    }

    /// `ssh-keygen -t <type> [-b bits] [-m <format>] -N <passphrase> -f <dir>/key -C fixture`.
    /// Returns the private key path; `<path>.pub` is beside it.
    ///
    /// A `nil` format omits `-m` entirely, which is how ssh-keygen writes its
    /// OWN `openssh-key-v1` container — the one file shape this decoder hands
    /// back rather than reads.
    static func sshKeygen(type: String, bits: Int?, format: Format?, passphrase: String?,
                          in dir: URL) async throws -> String {
        let path = dir.appendingPathComponent("key-\(UUID().uuidString)").path(percentEncoded: false)
        var args = ["-q", "-t", type, "-N", passphrase ?? "", "-f", path, "-C", "fixture"]
        if let format { args += ["-m", format.rawValue] }
        if let bits { args += ["-b", String(bits)] }
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: args)
        #expect(result.status == 0)
        return path
    }

    /// `openssl <args>`; returns stdout. LibreSSL 3.3.6 here (design table).
    @discardableResult
    static func openssl(_ args: [String]) async throws -> String {
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/openssl"), arguments: args)
        #expect(result.status == 0)
        return result.stdoutText
    }

    /// `ssh-keygen` refuses a private key file others can read (design
    /// record, "It refuses a copy whose mode is 0644"). Files ssh-keygen
    /// writes are already 0600; files openssl writes take the umask, so the
    /// oracle below cannot read them until this has run.
    static func restrict(_ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// The public key line `ssh-keygen -y` derives from the file — the external oracle.
    static func publicKeyLine(ofKeyAt path: String, passphrase: String?) async throws -> String {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-y", "-P", passphrase ?? "", "-f", path])
        #expect(result.status == 0)
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The base64 blob (second field) of a public key line, decoded.
    static func blob(ofPublicKeyLine line: String) -> Data? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// Reads `count` SSH strings (uint32 length + bytes) from a blob.
    ///
    /// `nil` on any short read: a blob that ends inside a length prefix or
    /// inside a string is not a blob with fewer fields, it is a blob the
    /// caller must not read at all.
    static func sshStrings(in blob: Data, count: Int) -> [Data]? {
        var fields: [Data] = []
        var index = blob.startIndex
        for _ in 0..<count {
            guard blob.distance(from: index, to: blob.endIndex) >= 4 else { return nil }
            var length = 0
            for _ in 0..<4 {
                length = (length << 8) | Int(blob[index])
                index = blob.index(after: index)
            }
            guard blob.distance(from: index, to: blob.endIndex) >= length else { return nil }
            let end = blob.index(index, offsetBy: length)
            fields.append(Data(blob[index..<end]))
            index = end
        }
        return fields
    }

    /// An SSH string: uint32 big-endian length, then the bytes.
    static func sshString(_ bytes: Data) -> Data {
        var out = Data()
        let length = UInt32(bytes.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(bytes)
        return out
    }

    /// PKCS#8 PEM for an Ed25519 seed: the fixed 16-byte PrivateKeyInfo
    /// prefix `30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20` and the seed.
    /// Built here because ssh-keygen 10.3 and LibreSSL 3.3.6 produce none (design table).
    static func ed25519PKCS8PEM(seed: Data) -> String {
        precondition(seed.count == 32)
        let prefix: [UInt8] = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                               0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
        let der = Data(prefix) + seed
        return "-----BEGIN PRIVATE KEY-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END PRIVATE KEY-----\n"
    }

    /// The `authorized_keys` line for an Ed25519 seed, computed rather than
    /// derived: `ssh-ed25519 <base64 of the two SSH strings> <comment>`.
    ///
    /// `ssh-keygen -y` is the oracle everywhere else here, but it answers
    /// "invalid format" for an Ed25519 PKCS#8 file (measured 2026-09-11,
    /// OpenSSH 10.3p1) — and that container is exactly the one the rig cell
    /// for this key type needs a public line for. The blob is RFC 8709 §4's:
    /// the algorithm name, then the 32-byte public key, each as an SSH
    /// string.
    static func ed25519PublicKeyLine(seed: Data, comment: String) throws -> String {
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
        let blob = sshString(Data("ssh-ed25519".utf8))
            + sshString(publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// A PBES2 file with an EXPLICIT SHA-256 PRF and AES-256-CBC, built here
    /// because no producer on this machine writes one: LibreSSL 3.3.6 has
    /// neither `-v2prf` nor `-scrypt`, and it writes no encrypted Ed25519
    /// PKCS#8 at all (design table, 2026-09-10).
    ///
    /// `declaredRounds` is what goes into the file; the key is always derived
    /// at `rounds`. They differ only for
    /// `PEMPrivateKeyDecoderTests.refusesAnAbsurdIterationCount`, where the
    /// file is refused before any key is derived, so no key at the declared
    /// count is ever needed.
    ///
    /// Lives here rather than in that suite since 2026-09-11, when the
    /// Ed25519 PKCS#8 rig cell of `FileKeyTypeIntegrationTests` needed the
    /// same builder; the body is unchanged by the move, and `rounds` gained
    /// the default the decoder suite was already passing.
    static func pbes2PEM(pkcs8DER: Data, passphrase: String,
                         rounds: Int = 2048, declaredRounds: Int? = nil) throws -> String {
        let salt = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let key = try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8), salt: salt, using: .sha256,
            outputByteCount: 32, unsafeUncheckedRounds: rounds)
        let iv = AES._CBC.IV()
        let ciphertext = try AES._CBC.encrypt(pkcs8DER, using: key, iv: iv)

        let pbes2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 13]
        let pbkdf2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 12]
        let hmacSHA256: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 2, 9]
        let aes256CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 42]

        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { outer in
            try outer.appendConstructedNode(identifier: .sequence) { algorithm in
                try algorithm.serialize(pbes2)
                try algorithm.appendConstructedNode(identifier: .sequence) { parameters in
                    try parameters.appendConstructedNode(identifier: .sequence) { kdf in
                        try kdf.serialize(pbkdf2)
                        try kdf.appendConstructedNode(identifier: .sequence) { kdfParameters in
                            try kdfParameters.serialize(ASN1OctetString(contentBytes: ArraySlice(salt)))
                            try kdfParameters.serialize(declaredRounds ?? rounds)
                            try kdfParameters.appendConstructedNode(identifier: .sequence) { prf in
                                try prf.serialize(hmacSHA256)
                                try prf.serialize(ASN1Null())
                            }
                        }
                    }
                    try parameters.appendConstructedNode(identifier: .sequence) { scheme in
                        try scheme.serialize(aes256CBC)
                        try scheme.serialize(ASN1OctetString(contentBytes: ArraySlice(Data(iv))))
                    }
                }
            }
            try outer.serialize(ASN1OctetString(contentBytes: ArraySlice(ciphertext)))
        }
        let der = Data(serializer.serializedBytes)
        return "-----BEGIN ENCRYPTED PRIVATE KEY-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END ENCRYPTED PRIVATE KEY-----\n"
    }

    /// A decoded key's KIND, with no payload.
    ///
    /// `DecodedPrivateKey` interpolated whole prints the components, and both
    /// an `Issue.record` message and a thrown error's description are exits
    /// that open only when a test fails — which is exactly when someone is
    /// reading them.
    static func kind(of decoded: PEMPrivateKeyDecoder.DecodedPrivateKey) -> String {
        switch decoded {
        case .rsa: return "an RSA key"
        case .ecdsa(let curve, _): return "an ECDSA key on \(curve)"
        case .ed25519: return "an Ed25519 key"
        }
    }

    /// The DER between a PEM file's boundaries.
    ///
    /// `.ignoreUnknownCharacters` because a base64 body's line ending may be
    /// CRLF, and "\r\n" is ONE Swift `Character` — a split on "\n" does not
    /// separate it, so the carriage returns survive into the joined string.
    static func der(ofPEM text: String) -> Data? {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body, options: [.ignoreUnknownCharacters])
    }
}
