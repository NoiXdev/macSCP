import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// An RSA **host** key, verified under RFC 8332's `rsa-sha2-512`.
///
/// RFC 8332 splits two identifiers that older SSH implementations conflated:
/// the algorithm NAME negotiated in the key exchange (`rsa-sha2-512`, whose
/// signatures hash with SHA-512) and the key blob TYPE that identifies the
/// key on the wire, which stays `ssh-rsa` for every RSA key regardless of the
/// digest. `publicKeyPrefix` is the blob type; `hostKeyAlgorithmNames` — a
/// requirement the fork adds, see the `swift-nio-ssh` note in `Package.swift`
/// — is the negotiated name. The SHA-1 algorithm, also spelled `ssh-rsa`, is
/// never offered: it is not among the names, and no signature type declaring
/// it is registered, so a server cannot negotiate macSCP down to it.
///
/// This type verifies only. macSCP never presents an RSA host key, and RSA
/// **client** authentication goes through `AgentBackedPrivateKey` instead.
struct RSASHA2HostKey: NIOSSHPublicKeyProtocol, Sendable {
    static let publicKeyPrefix = "ssh-rsa"

    /// One name, deliberately: the strongest of the two RFC 8332 digests.
    /// A server that offers only `rsa-sha2-256` therefore still fails to
    /// negotiate, which is a smaller loss than carrying a second digest
    /// through verification.
    static let hostKeyAlgorithmNames = [RSASHA2Signature.signaturePrefix]

    /// The smallest modulus this type will accept, in bits.
    ///
    /// 1024 is OpenSSH's own `RequiredRSASize` default (`ssh_config`), and
    /// the reason to match it rather than raise it is compatibility: a
    /// server OpenSSH connects to should not be a server macSCP refuses.
    /// Below it, factoring is what breaks the trust model rather than
    /// theft — and a factored host key reconstructs the SAME public key, so
    /// TOFU's mismatch stop never fires against the impersonation. The
    /// refusal therefore has to happen at parse, before anything is
    /// remembered.
    static let minimumModulusBits = 1024

    struct ParseError: Error, Equatable {
        let reason: String
    }

    /// `mpint e` and `mpint n` exactly as they arrived, so `write(to:)` can
    /// put back the bytes the server hashed. The exchange hash covers the
    /// server's own serialization of `K_S`, and NIOSSH recomputes it from
    /// this type — a re-encoding that merely means the same integer (a
    /// dropped or added leading zero) would break the handshake.
    private let exponent: [UInt8]
    private let modulus: [UInt8]

    /// Built once, at parse time, so a key whose numbers cannot form an RSA
    /// key fails the handshake rather than silently failing verification.
    private let verifier: _RSA.Signing.PublicKey

    private init(exponent: [UInt8], modulus: [UInt8]) throws {
        let modulusBits = Self.bitWidth(of: modulus)
        guard modulusBits >= Self.minimumModulusBits else {
            throw ParseError(reason: "RSA host key of \(modulusBits) bits is below the accepted minimum")
        }
        self.exponent = exponent
        self.modulus = modulus
        do {
            // `_RSA.Signing.PublicKey(n:e:)` wants bare big-endian integers;
            // an mpint carries a leading 0x00 whenever the top bit of its
            // first byte is set.
            verifier = try _RSA.Signing.PublicKey(
                n: Data(Self.strippingLeadingZeros(modulus)),
                e: Data(Self.strippingLeadingZeros(exponent)))
        } catch {
            throw ParseError(reason: "not an RSA public key")
        }
    }

    /// The blob body, without the leading `string "ssh-rsa"` that NIOSSH
    /// writes itself. NIOSSH compares custom keys for equality by this and
    /// the prefix.
    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    /// The body of an `ssh-rsa` key blob is `mpint e`, `mpint n`. The
    /// algorithm identifier ahead of it has already been consumed by
    /// `ByteBuffer.readSSHHostKey` when this is called.
    static func read(from buffer: inout ByteBuffer) throws -> RSASHA2HostKey {
        guard let exponent = buffer.readSSHStringField() else {
            throw ParseError(reason: "missing mpint e")
        }
        guard let modulus = buffer.readSSHStringField() else {
            throw ParseError(reason: "missing mpint n")
        }
        return try RSASHA2HostKey(exponent: exponent, modulus: modulus)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHStringField(exponent) + buffer.writeSSHStringField(modulus)
    }

    /// PKCS#1 v1.5 over SHA-512, as `rsa-sha2-512` defines it.
    ///
    /// A signature of any other type is refused outright — including one
    /// typed `ssh-rsa`, whose bytes may well verify: accepting it would be
    /// the SHA-1 downgrade this type exists to avoid.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA2Signature else {
            return false
        }
        return verifier.isValidSignature(
            _RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation),
            for: SHA512.hash(data: Data(data)),
            padding: .insecurePKCS1v1_5)
    }

    /// The width of an mpint's value, counted from its minimal encoding —
    /// an mpint's byte count answers a different question, since it carries
    /// a leading `0x00` whenever the top bit is set (which an RSA modulus
    /// always has).
    private static func bitWidth(of mpint: [UInt8]) -> Int {
        let magnitude = strippingLeadingZeros(mpint)
        guard let first = magnitude.first, first != 0 else { return 0 }
        return (magnitude.count - 1) * 8 + (UInt8.bitWidth - first.leadingZeroBitCount)
    }

    private static func strippingLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        while bytes.first == 0, bytes.count > 1 {
            bytes.removeFirst()
        }
        return bytes
    }
}

/// An `rsa-sha2-512` signature: on the wire `string "rsa-sha2-512"` followed
/// by `string signature`, where the signature is the PKCS#1 v1.5 block.
/// NIOSSH reads and writes the leading identifier itself from
/// `signaturePrefix`, so only the payload string is handled here.
///
/// Registering this type is also what keeps `ssh-rsa` signatures
/// unparseable: `ByteBuffer.readSSHSignature` dispatches on the identifier,
/// and macSCP registers no type that answers to the SHA-1 name.
struct RSASHA2Signature: NIOSSHSignatureProtocol, Sendable {
    static let signaturePrefix = "rsa-sha2-512"

    struct ParseError: Error, Equatable {
        let reason: String
    }

    let rawRepresentation: Data

    init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHStringField([UInt8](rawRepresentation))
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA2Signature {
        guard let bytes = buffer.readSSHStringField() else {
            throw ParseError(reason: "missing signature payload")
        }
        return RSASHA2Signature(rawRepresentation: Data(bytes))
    }
}

/// The custom host-key algorithms macSCP adds to NIOSSH's process-global
/// registry.
///
/// Registration is a process-wide side effect with no public undo, and
/// NIOSSH itself de-duplicates by type identity — so this is idempotent
/// twice over, and callers connecting on any path may simply call
/// `registerOnce()` first.
///
/// It calls `NIOSSHAlgorithms.register(publicKey:signature:)` directly
/// rather than going through Citadel's `SSHAlgorithms.publicKeyAlgorihtms`,
/// which does exactly this call and nothing else (`Modification.register()`,
/// Citadel `Client.swift`). The reason is measured: that field is a
/// `Modification<T: Sendable>` instantiated at
/// `(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)`, neither of
/// which is `Sendable`, so populating it from a `.swiftLanguageMode(.v6)`
/// target emits Sendable warnings that no import attribute suppresses
/// (`.superpowers/sdd/2026-09-02-rsa-host-key-spike`).
///
/// ### Who parses an incoming `ssh-rsa` blob
///
/// NIOSSH resolves an incoming key blob by walking its registration list and
/// taking the FIRST registered type whose `publicKeyPrefix` matches. Since
/// Citadel `0.12.1-noix.3` typed its RSA user keys `ssh-rsa` again (RFC 8332
/// §3), FOUR types in this dependency graph declare that prefix: this one,
/// Citadel's `Insecure.RSA.SHA2PublicKey<RSASHA2_256>` and
/// `<RSASHA2_512>`, and Citadel's SHA-1 `Insecure.RSA.PublicKey`.
///
/// Only a REGISTERED type takes part in that lookup, and in macSCP's process
/// exactly ONE of the four is registered: this one. Counted 2026-09-02 —
/// `NIOSSHAlgorithms.register(publicKey:signature:)` is reached from one
/// place in macSCP (the `registration` below) and from two places in Citadel
/// (`Client.swift:49` and `:53`), both inside
/// `SSHAlgorithms.Modification.register()`, which runs only for an
/// `algorithms:` argument passed to a connect. macSCP passes none — its only
/// dial is `CitadelFileSystem.connectWithRegisteredAlgorithms`, which takes
/// Citadel's default `SSHAlgorithms()`, whose three `Modification` fields are
/// all `nil` — and nothing in Citadel uses its own `SSHAlgorithms.all`.
/// Citadel's RSA user keys are only ever WRITTEN, and the write path never
/// consults the registry: it writes the concrete instance's own prefix.
///
/// So this type wins the `ssh-rsa` lookup by being the only candidate, and
/// the host-key path it serves is pinned live by `HostKeyTypeIntegrationTests`
/// against the rig's RSA-only `sshd` on port 2235.
enum HostKeyAlgorithms {
    /// A `static let` runs its initializer at most once, on first access,
    /// however many threads reach it.
    private static let registration: Void = {
        NIOSSHAlgorithms.register(publicKey: RSASHA2HostKey.self, signature: RSASHA2Signature.self)
    }()

    /// Registers the algorithms if they are not registered yet. Called
    /// before every `SSHClient.connect` in `CitadelFileSystem`, because the
    /// registry has to hold the type before the key exchange builds its
    /// offer.
    static func registerOnce() {
        _ = registration
    }
}

extension ByteBuffer {
    /// NIOSSH's own `readSSHString`/`writeSSHString` are internal to that
    /// module, so this file carries its own uint32-length-prefixed reader
    /// and writer for the `string` fields of a key or signature blob.
    /// Leaves the reader index untouched on a short read.
    fileprivate mutating func readSSHStringField() -> [UInt8]? {
        let start = readerIndex
        guard let length = readInteger(endianness: .big, as: UInt32.self),
              let bytes = readBytes(length: Int(length))
        else {
            moveReaderIndex(to: start)
            return nil
        }
        return bytes
    }

    @discardableResult
    fileprivate mutating func writeSSHStringField(_ bytes: [UInt8]) -> Int {
        writeInteger(UInt32(bytes.count), endianness: .big) + writeBytes(bytes)
    }
}
