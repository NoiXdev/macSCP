import Foundation
import Testing
import macSCPCore

/// `SSHKeyConverter`, measured against the same `ssh-keygen`/`openssl`
/// producers `PEMPrivateKeyDecoderTests` uses.
///
/// Every key is generated at RUNTIME into a temporary directory the test
/// removes — nothing here is checked in.
@Suite("SSHKeyConverter", .timeLimit(.minutes(2)))
struct SSHKeyConverterTests {
    /// Five characters at least: ssh-keygen refuses a shorter one. Never
    /// written into an `#expect` expression's source text — see
    /// `PEMPrivateKeyDecoderTests.passphrase` for why.
    private static let passphrase = "fixture-passphrase-2026"

    /// The five producer shapes `copyAsOpenSSH` is measured against
    /// (design table, "`ssh-keygen -p -P <pass> -N <pass> -f <copy>`
    /// rewrote every one of these copies").
    enum Producer: CustomStringConvertible, Sendable {
        case pemRSAPlain
        case pemECDSA256Encrypted
        case pkcs8RSAEncrypted
        case opensslLegacyDESEDE3
        case opensslPBES2DESEDE3

        var description: String {
            switch self {
            case .pemRSAPlain: return "PEM RSA plain"
            case .pemECDSA256Encrypted: return "PEM ECDSA-256 encrypted"
            case .pkcs8RSAEncrypted: return "PKCS8 RSA encrypted"
            case .opensslLegacyDESEDE3: return "openssl legacy DES-EDE3"
            case .opensslPBES2DESEDE3: return "openssl PBES2 DES-EDE3"
            }
        }
    }

    /// Builds one source file for `producer` in `dir`, returning its path
    /// and the passphrase (if any) that opens it.
    ///
    /// The two openssl shapes start from a plain PKCS#1 RSA key written by
    /// ssh-keygen, then `restrict` it to 0600: openssl's own output takes
    /// the umask, and the oracle (`ssh-keygen -y`) cannot read a 0644 file
    /// any more than `ssh-keygen -p` can (`PEMFixtures.restrict`'s own
    /// doc comment).
    private func makeSource(_ producer: Producer, in dir: URL) async throws -> (path: String, passphrase: String?) {
        switch producer {
        case .pemRSAPlain:
            let path = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                       passphrase: nil, in: dir)
            return (path, nil)
        case .pemECDSA256Encrypted:
            let path = try await PEMFixtures.sshKeygen(type: "ecdsa", bits: 256, format: .pem,
                                                       passphrase: Self.passphrase, in: dir)
            return (path, Self.passphrase)
        case .pkcs8RSAEncrypted:
            let path = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pkcs8,
                                                       passphrase: Self.passphrase, in: dir)
            return (path, Self.passphrase)
        case .opensslLegacyDESEDE3:
            let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                            passphrase: nil, in: dir)
            let path = dir.appendingPathComponent("legacy-des3-\(UUID().uuidString).pem").path(percentEncoded: false)
            try await PEMFixtures.openssl(["rsa", "-in", plainPath, "-des3",
                                           "-passout", "pass:\(Self.passphrase)", "-out", path])
            try PEMFixtures.restrict(path)
            return (path, Self.passphrase)
        case .opensslPBES2DESEDE3:
            let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                            passphrase: nil, in: dir)
            let path = dir.appendingPathComponent("pbes2-des3-\(UUID().uuidString).pem").path(percentEncoded: false)
            try await PEMFixtures.openssl(["pkcs8", "-topk8", "-in", plainPath, "-v2", "des3",
                                           "-passout", "pass:\(Self.passphrase)", "-out", path])
            try PEMFixtures.restrict(path)
            return (path, Self.passphrase)
        }
    }

    // MARK: - 1: every shape converts, the source is untouched

    @Test("every PEM variant converts to an OpenSSH copy and the source is untouched",
          arguments: [Producer.pemRSAPlain, .pemECDSA256Encrypted, .pkcs8RSAEncrypted,
                      .opensslLegacyDESEDE3, .opensslPBES2DESEDE3])
    func convertsEveryVariant(_ producer: Producer) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (sourcePath, passphrase) = try await makeSource(producer, in: dir)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("converted-\(UUID().uuidString)")

        let sourceLine = try await PEMFixtures.publicKeyLine(ofKeyAt: sourcePath, passphrase: passphrase)
        let beforeBytes = try Data(contentsOf: sourceURL)
        let beforeModified = try FileManager.default
            .attributesOfItem(atPath: sourcePath)[.modificationDate] as? Date

        let converted = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: passphrase)
        #expect(converted)

        let destinationText = try String(contentsOf: destinationURL, encoding: .utf8)
        let firstLine = destinationText
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let firstLineIsTheBoundary = firstLine == SSHKeyConverter.opensshBoundary
        #expect(firstLineIsTheBoundary)

        let mode = try FileManager.default
            .attributesOfItem(atPath: destinationURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let afterBytes = try Data(contentsOf: sourceURL)
        let sourceBytesUnchanged = afterBytes == beforeBytes
        #expect(sourceBytesUnchanged)
        let afterModified = try FileManager.default
            .attributesOfItem(atPath: sourcePath)[.modificationDate] as? Date
        let sourceMTimeUnchanged = afterModified == beforeModified
        #expect(sourceMTimeUnchanged)

        let destinationLine = try await PEMFixtures.publicKeyLine(
            ofKeyAt: destinationURL.path(percentEncoded: false), passphrase: passphrase)
        let samePublicKey = destinationLine == sourceLine
        #expect(samePublicKey)
    }

    // MARK: - 2: an already-OpenSSH source

    @Test("an OpenSSH source is copied without a conversion")
    func copiesOpenSSHSourceWithoutConverting() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No `-m`: ssh-keygen's own default output, `openssh-key-v1`.
        let sourcePath = try await PEMFixtures.sshKeygen(type: "ed25519", bits: nil, format: nil,
                                                          passphrase: nil, in: dir)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("copy-\(UUID().uuidString)")
        let beforeBytes = try Data(contentsOf: sourceURL)

        let converted = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: nil)
        #expect(converted == false)

        let destinationBytes = try Data(contentsOf: destinationURL)
        let bytesIdentical = destinationBytes == beforeBytes
        #expect(bytesIdentical)
    }

    // MARK: - 3: a wrong passphrase

    @Test("a wrong passphrase leaves no destination")
    func wrongPassphraseLeavesNoDestination() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                          passphrase: Self.passphrase, in: dir)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("wrong-\(UUID().uuidString)")
        let wrong = "not-" + Self.passphrase

        var caught: SSHKeyConverter.ConversionError?
        do {
            _ = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: wrong)
        } catch let error as SSHKeyConverter.ConversionError {
            caught = error
        }
        #expect(caught == .conversionFailed)
        let destinationMissing = !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        #expect(destinationMissing)
    }

    // MARK: - 4: an existing destination

    @Test("an existing destination is refused before anything is written")
    func existingDestinationIsRefused() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                          passphrase: nil, in: dir)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("existing-\(UUID().uuidString)")
        let placeholder = Data("not a key".utf8)
        try placeholder.write(to: destinationURL)

        var caught: SSHKeyConverter.ConversionError?
        do {
            _ = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: nil)
        } catch let error as SSHKeyConverter.ConversionError {
            caught = error
        }
        #expect(caught == .destinationExists)
        let destinationBytes = try Data(contentsOf: destinationURL)
        let destinationUnchanged = destinationBytes == placeholder
        #expect(destinationUnchanged)
    }

    // MARK: - 4b: the 0600 guarantee against a world-readable SOURCE

    /// Every other fixture in this file is already 0600 before
    /// `copyAsOpenSSH` runs (`ssh-keygen`'s own output, or `PEMFixtures.restrict`
    /// on the openssl shapes), and `FileManager.copyItem` preserves the
    /// SOURCE's mode onto the destination — so none of the tests above would
    /// notice the destination's own `setAttributes(0600)` call going missing.
    /// These two start from a 0644 source instead, one on each branch
    /// (already-OpenSSH short-circuit, needs-conversion), so a missing
    /// `setAttributes` call is visible on the branch where nothing else
    /// would catch it.
    @Test("a world-readable OpenSSH source still yields a 0600 destination")
    func worldReadableOpenSSHSourceYields0600Destination() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = try await PEMFixtures.sshKeygen(type: "ed25519", bits: nil, format: nil,
                                                          passphrase: nil, in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourcePath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("world-readable-openssh-\(UUID().uuidString)")

        let converted = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: nil)
        #expect(converted == false)

        let mode = try FileManager.default
            .attributesOfItem(atPath: destinationURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("a world-readable PEM source still yields a 0600 destination")
    func worldReadablePEMSourceYields0600Destination() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                          passphrase: nil, in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourcePath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = dir.appendingPathComponent("world-readable-pem-\(UUID().uuidString)")

        let converted = try SSHKeyConverter.copyAsOpenSSH(from: sourceURL, to: destinationURL, passphrase: nil)
        #expect(converted)

        let mode = try FileManager.default
            .attributesOfItem(atPath: destinationURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    // MARK: - 5: the terminal command line

    @Test("the command line quotes the path for a POSIX shell")
    func quotesThePathForAPOSIXShell() {
        let commandLine = SSHKeyConverter.inPlaceCommandLine(forKeyAt: "/tmp/it's here/id rsa")
        #expect(commandLine == "ssh-keygen -p -f '/tmp/it'\\''s here/id rsa'")
    }

    // MARK: - 6: what isOpenSSHFormat reads

    @Test("isOpenSSHFormat reads only the first non-blank line")
    func isOpenSSHFormatReadsOnlyTheFirstNonBlankLine() throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let leadingBlankLines = dir.appendingPathComponent("leading-blank.txt")
        try "\n\n\(SSHKeyConverter.opensshBoundary)\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: leadingBlankLines, atomically: true, encoding: .utf8)
        #expect(SSHKeyConverter.isOpenSSHFormat(fileAt: leadingBlankLines))

        let boundaryNotFirst = dir.appendingPathComponent("boundary-not-first.txt")
        try "-----BEGIN RSA PRIVATE KEY-----\n\(SSHKeyConverter.opensshBoundary)\n"
            .write(to: boundaryNotFirst, atomically: true, encoding: .utf8)
        #expect(SSHKeyConverter.isOpenSSHFormat(fileAt: boundaryNotFirst) == false)

        let notAKeyAtAll = dir.appendingPathComponent("not-a-key.txt")
        try "not a key at all\n".write(to: notAKeyAtAll, atomically: true, encoding: .utf8)
        #expect(SSHKeyConverter.isOpenSSHFormat(fileAt: notAKeyAtAll) == false)
    }
}
