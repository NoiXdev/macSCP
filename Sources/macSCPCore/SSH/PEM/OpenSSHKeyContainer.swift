import Foundation
import NIOCore

/// Writes an `openssh-key-v1` container in memory, so a key read out of a PEM
/// file can be handed to a connection.
///
/// Why a container and not components: Citadel exposes no way to build an
/// `Insecure.RSA.PrivateKey` from n / e / d outside its own module — its
/// component initialiser takes BoringSSL `BIGNUM` pointers, and
/// `CCryptoBoringSSL` is not a product this target can import (design,
/// 2026-09-10). Its `init(sshRsa:)` parses this container, so this is the
/// door that is open.
///
/// Nothing here reaches disk. It is NOT a wiping writer, though: `d`, `p` and
/// `q` pass through an intermediate `ByteBuffer` and a base64 `String` on the
/// way out, and neither is zeroed — they are released when they are released,
/// and the returned string lives at least as long as the caller holds it. What
/// this type guarantees is only that none of it is written to a file.
public enum OpenSSHKeyContainer {
    private static let magic = "openssh-key-v1"
    private static let keyType = "ssh-rsa"
    /// Cipher `none` has a block size of 8 in Citadel's parser, and the
    /// parser requires the padding to be SHORTER than it — a writer that pads
    /// an aligned section with a full block writes a file that parser
    /// refuses.
    private static let blockSize = 8
    private static let base64Columns = 70

    /// An unencrypted `openssh-key-v1` PEM string holding one RSA key.
    public static func unencryptedRSA(_ key: PEMPrivateKeyDecoder.RSAPrivateKeyComponents,
                                      comment: String) -> String {
        var publicBlob = ByteBuffer()
        writeString(keyType, to: &publicBlob)
        writeMPInt(key.e, to: &publicBlob)
        writeMPInt(key.n, to: &publicBlob)

        // The check words are compared with each other by the parser and are
        // what an encrypted container's decryption is verified with. Random,
        // as OpenSSH writes them.
        let check = UInt32.random(in: 0...UInt32.max)
        var privateSection = ByteBuffer()
        privateSection.writeInteger(check)
        privateSection.writeInteger(check)
        writeString(keyType, to: &privateSection)
        // The order Citadel's reader consumes: n, e, d, iqmp, p, q.
        writeMPInt(key.n, to: &privateSection)
        writeMPInt(key.e, to: &privateSection)
        writeMPInt(key.d, to: &privateSection)
        writeMPInt(key.iqmp, to: &privateSection)
        writeMPInt(key.p, to: &privateSection)
        writeMPInt(key.q, to: &privateSection)
        writeString(comment, to: &privateSection)
        let padding = (blockSize - privateSection.readableBytes % blockSize) % blockSize
        if padding > 0 {
            for index in 1...padding { privateSection.writeInteger(UInt8(index)) }
        }

        var container = ByteBuffer()
        container.writeString(magic)
        container.writeInteger(UInt8(0x00))
        writeString("none", to: &container)   // cipher
        writeString("none", to: &container)   // kdfname
        writeString("", to: &container)       // kdfoptions
        container.writeInteger(UInt32(1))     // one key
        writeBuffer(publicBlob, to: &container)
        writeBuffer(privateSection, to: &container)

        let bytes = Data(container.readBytes(length: container.readableBytes) ?? [])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + wrapped(bytes.base64EncodedString())
            + "-----END OPENSSH PRIVATE KEY-----\n"
    }

    // MARK: - The wire primitives, written here rather than borrowed

    /// An SSH string: uint32 big-endian length, then the bytes. Citadel's own
    /// `writeSSHString` is internal to it, and a container this project writes
    /// should not depend on another module's internals to stay well-formed.
    private static func writeString(_ value: String, to buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt32(value.utf8.count))
        buffer.writeString(value)
    }

    private static func writeBuffer(_ value: ByteBuffer, to buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt32(value.readableBytes))
        var value = value
        buffer.writeBuffer(&value)
    }

    /// An SSH mpint: the magnitude, with a `0x00` in front when its top bit is
    /// set so it does not read as negative.
    private static func writeMPInt(_ magnitude: Data, to buffer: inout ByteBuffer) {
        let needsSignByte = (magnitude.first ?? 0x00) & 0x80 != 0
        buffer.writeInteger(UInt32(magnitude.count + (needsSignByte ? 1 : 0)))
        if needsSignByte { buffer.writeInteger(UInt8(0x00)) }
        buffer.writeBytes(magnitude)
    }

    private static func wrapped(_ base64: String) -> String {
        var lines: [String] = []
        var rest = Substring(base64)
        while rest.isEmpty == false {
            let line = rest.prefix(base64Columns)
            lines.append(String(line))
            rest = rest.dropFirst(line.count)
        }
        return lines.map { $0 + "\n" }.joined()
    }
}
