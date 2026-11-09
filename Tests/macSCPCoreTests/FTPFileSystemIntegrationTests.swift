import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// Runs only with `MACSCP_ITEST=1` and the rig's FTP services up
/// (`docker compose -f docker/test-server/compose.yml up -d ftpd ftpd-nomlsd`,
/// from the main checkout), which bring up one ProFTPD image twice
/// (`docker/test-server/ftpd/`, README.md "The FTP rig"):
///   - `ftpd`        port 2121: advertises `MLST`, which the client reads as
///                   `MLSD`, and offers explicit FTPS
///                   (`AUTH TLS`) on the same port; port 2990: implicit FTPS;
///   - `ftpd-nomlsd` port 2122: the same daemon with `MLSD` neither advertised
///                   nor accepted, so `LIST` runs against a real server.
/// Both take `ftpitest` / `testpass` here (`testuser` is the CLI matrix's, and
/// the two are separate on purpose: `CLIMatrixFTPITests` counts the daemon's
/// `testuser` logins to show a diagnosis sent none, and this suite's logins
/// must not land in that count). Chrooted, so the session root is
/// `/`, and carry `hello.txt`, `sub/` and two symlinks the entrypoint creates.
///
/// **What this suite is for, and what it is not.** `LoopbackFTPServer` carries
/// the protocol's behaviour and every hostile case, ungated. This file carries
/// the INTEROPERABILITY claim and nothing else: that a daemon somebody else
/// wrote, answering in its own words, is understood. The first measurement it
/// made is the reason the claim is worth making — see
/// `theRigDaemonsListingAgreesWithTheMLSDParser`.
@Suite(
    "FTPFileSystem against the Docker rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
struct FTPFileSystemIntegrationTests {

    // MARK: - The rig's coordinates

    /// Which of the rig's daemons a case dials. `CaseIterable` so a
    /// parameterised case covers both without a list to keep in step.
    enum Daemon: String, CaseIterable, CustomStringConvertible {
        case withMLSD
        case withoutMLSD

        var port: Int {
            switch self {
            case .withMLSD: return 2121
            case .withoutMLSD: return 2122
            }
        }

        var description: String { rawValue }
    }

    private static let implicitTLSPort = 2990
    private static let host = "127.0.0.1"

    // MARK: - Helpers

    private static func trustDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftp-trust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `FTPConnectionConfig` the rig's user dials with.
    private static func config(
        port: Int, security: FTPSecurityMode = .plain
    ) -> FTPConnectionConfig {
        FTPConnectionConfig(
            host: host, port: port, username: "ftpitest", security: security,
            password: "testpass")
    }

    private static func connect(
        port: Int, security: FTPSecurityMode = .plain, slots: Int = 2,
        decider: CertificateDecider = .refusing,
        trustStore: TrustedCertificateStore? = nil
    ) async throws -> FTPFileSystem {
        try await FTPFileSystem.connect(
            config(port: port, security: security),
            transferSlots: slots, certificateDecider: decider, timeout: .seconds(30),
            trustStore: trustStore)
    }

    private static func write(
        _ fs: FTPFileSystem, path: String, content: Data
    ) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(content)
        continuation.finish()
        try await fs.write(path: path, contents: stream)
    }

    private static func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var result = Data()
        for try await chunk in stream { result.append(chunk) }
        return result
    }

    /// Deterministic pseudo-random bytes (a simple LCG), the same generator
    /// `WebDAVFileSystemIntegrationTests` uses: large enough to span several
    /// 64 KiB chunks and reproducible, so a failure names the same bytes twice.
    private static func pseudoRandomBytes(count: Int) -> Data {
        var state: UInt64 = 0x1234_5678_9abc_def0
        var body = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            body.append(UInt8((state >> 33) & 0xFF))
        }
        return body
    }

    /// Runs `body`, then removes `paths` whatever it did, and rethrows. The
    /// rig is persistent, so a failing case must not leave its litter for the
    /// next run to list.
    private static func withLitter(
        _ fs: FTPFileSystem, _ paths: [String],
        _ body: () async throws -> Void
    ) async throws {
        var caught: (any Error)?
        do {
            try await body()
        } catch {
            caught = error
        }
        for path in paths {
            try? await fs.deleteTree(at: path)
        }
        await fs.disconnect()
        if let caught { throw caught }
    }

    private actor AskCounter {
        private(set) var count = 0
        func asked() { count += 1 }
    }

    // MARK: - Full CRUD

    /// The whole CRUD cycle, once against each daemon: the one that lists with
    /// `MLSD` and the one that cannot. Every step is a different command
    /// (`MKD`, `STOR`, `SIZE`/`MDTM` or a parent listing, `RNFR`/`RNTO`,
    /// `RETR`, `DELE`, `RMD`), so a daemon that reads one of them differently
    /// fails at a step with a name.
    @Test(arguments: Daemon.allCases)
    func aFullCRUDRoundTripRunsAgainstTheRigDaemon(daemon: Daemon) async throws {
        let fs = try await Self.connect(port: daemon.port)
        let folder = "/ftp-itest-crud-\(UUID().uuidString)"
        let original = folder + "/original.bin"
        let renamed = folder + "/renamed.bin"
        let payload = Self.pseudoRandomBytes(count: 150 * 1024)

        try await Self.withLitter(fs, [folder]) {
            try await fs.createDirectory(at: folder)
            let directory = try await fs.stat(path: folder)
            #expect(directory.isDirectory, "\(daemon): a created folder did not stat as one")

            try await Self.write(fs, path: original, content: payload)
            let uploaded = try await fs.stat(path: original)
            #expect(uploaded.isDirectory == false)
            #expect(uploaded.size == UInt64(payload.count), "\(daemon): the stat size is wrong")

            let listed = try await fs.list(path: folder)
            #expect(listed.map(\.name) == ["original.bin"], "\(daemon): the listing is wrong")
            #expect(listed.first?.size == UInt64(payload.count))

            try await fs.rename(from: original, to: renamed)
            let afterRename = try await fs.list(path: folder)
            #expect(afterRename.map(\.name) == ["renamed.bin"])

            let downloaded = try await Self.drain(try await fs.readStream(path: renamed))
            #expect(downloaded == payload, "\(daemon): the downloaded bytes differ")

            try await fs.delete(path: renamed)
            #expect(try await fs.list(path: folder).isEmpty)

            try await fs.deleteTree(at: folder)
            let gone: Bool
            do {
                _ = try await fs.stat(path: folder)
                gone = false
            } catch RemoteFSError.notFound {
                gone = true
            }
            #expect(gone, "\(daemon): a deleted folder still stats")
        }
    }

    // MARK: - TLS

    /// Explicit FTPS against the daemon's control port: the connection starts
    /// in the clear, `AUTH TLS` upgrades it, `PROT P` protects the data
    /// connections — and ProFTPD's default REQUIRES each data connection to
    /// resume the control connection's TLS session, so a transfer here is the
    /// first time the client's session reuse has met a server that enforces
    /// it other than the in-process stub.
    ///
    /// The certificate is self-signed and generated when the container
    /// starts, so the decider is asked exactly once and remembers; the second
    /// dial, with the SAME store and a decider that would say no, must still
    /// connect.
    @Test func anExplicitTLSSessionCompletesAgainstTheRigDaemon() async throws {
        let directory = Self.trustDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)
        let asked = AskCounter()

        let fs = try await Self.connect(
            port: Daemon.withMLSD.port, security: .explicitTLS,
            decider: .asking { _ in await asked.asked(); return true }, trustStore: store)
        let path = "/ftp-itest-tls-\(UUID().uuidString).bin"
        let payload = Self.pseudoRandomBytes(count: 200 * 1024)
        try await Self.withLitter(fs, [path]) {
            try await Self.write(fs, path: path, content: payload)
            let downloaded = try await Self.drain(try await fs.readStream(path: path))
            #expect(downloaded == payload, "the bytes differ across a protected data connection")
            #expect(try await fs.list(path: "/").contains { $0.name == path.dropFirst().description })
        }
        let firstDialAsked = await asked.count
        #expect(firstDialAsked == 1, "the untrusted certificate was asked about \(firstDialAsked) times")
        let remembered = try store.find(host: Self.host, port: Daemon.withMLSD.port)
        #expect(remembered != nil, "the accepted certificate was not remembered")

        // Remembered, so a refusing decider is never consulted.
        let again = try await Self.connect(
            port: Daemon.withMLSD.port, security: .explicitTLS, decider: .refusing,
            trustStore: store)
        let reachable = (try? await again.list(path: "/").isEmpty) != nil
        await again.disconnect()
        #expect(reachable, "a remembered certificate was refused on the second dial")
    }

    /// Many protected transfers in a row on ONE control connection, against a
    /// daemon that requires each data connection to resume its session.
    ///
    /// `FTPSessionVault`'s own measurement (against `LoopbackFTPServer`, which
    /// is BoringSSL) is that a control connection holds two tickets and each
    /// is used once, so a third protected transfer is refused: "a backend that
    /// stops transferring after the second file". That is a property of the
    /// server's TLS library as much as of the client, so it is asked of the
    /// rig's daemon (OpenSSL) here, with a single transfer slot so every
    /// transfer shares one control connection. Twelve, well past two.
    @Test func aLongProtectedSessionKeepsItsDataConnectionsResuming() async throws {
        let directory = Self.trustDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fs = try await Self.connect(
            port: Daemon.withMLSD.port, security: .explicitTLS, slots: 1,
            decider: .asking { _ in true },
            trustStore: TrustedCertificateStore(directory: directory))
        let path = "/ftp-itest-long-\(UUID().uuidString).bin"
        let payload = Self.pseudoRandomBytes(count: 20 * 1024)
        try await Self.withLitter(fs, [path]) {
            try await Self.write(fs, path: path, content: payload)
            for round in 1...12 {
                let downloaded = try await Self.drain(try await fs.readStream(path: path))
                #expect(downloaded == payload, "transfer \(round) of 12 returned other bytes")
            }
        }
    }

    /// Implicit FTPS on the daemon's own port: TLS from the first byte, before
    /// the greeting. The same upload and download as above, because the data
    /// connection is where an implicit-mode server differs.
    @Test func anImplicitTLSSessionCompletesAgainstTheRigDaemon() async throws {
        let directory = Self.trustDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)

        let fs = try await Self.connect(
            port: Self.implicitTLSPort, security: .implicitTLS,
            decider: .asking { _ in true }, trustStore: store)
        let path = "/ftp-itest-implicit-\(UUID().uuidString).bin"
        let payload = Self.pseudoRandomBytes(count: 100 * 1024)
        try await Self.withLitter(fs, [path]) {
            try await Self.write(fs, path: path, content: payload)
            let downloaded = try await Self.drain(try await fs.readStream(path: path))
            #expect(downloaded == payload)
        }
    }

    /// A certificate nobody has trusted is refused when the decider says no,
    /// and the refusal is a failed dial, not a connection.
    @Test func anUntrustedCertificateIsRefusedAgainstTheRigDaemon() async throws {
        let directory = Self.trustDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome: Result<Void, any Error>
        do {
            let fs = try await Self.connect(
                port: Daemon.withMLSD.port, security: .explicitTLS, decider: .refusing,
                trustStore: TrustedCertificateStore(directory: directory))
            await fs.disconnect()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        if case .success = outcome { Issue.record("an untrusted certificate was accepted by a refusing decider") }
    }

    // MARK: - Resumption

    /// A download resumed with `REST` and an upload interrupted and sent
    /// again, both against the real daemon, both compared BYTE FOR BYTE.
    ///
    /// **What "resumed upload" means for this backend is a restart**, on
    /// purpose: `supportsAppendResume` is `false`
    /// (`FTPFileSystem.supportsAppendResume` carries the argument), so the
    /// engine never asks the daemon for `REST` before `STOR`, and `.append`
    /// is refused before the wire. This case therefore asserts the pieces a
    /// resumed upload is made of: the refusal, and that a second full write
    /// over a shorter earlier one leaves exactly the new bytes with no splice.
    /// The download half is the real resume: the head is read, then the tail
    /// from the offset, and the two concatenate to the original.
    @Test func aResumedUploadAndDownloadMatchByteForByte() async throws {
        let fs = try await Self.connect(port: Daemon.withMLSD.port)
        let path = "/ftp-itest-resume-\(UUID().uuidString).bin"
        let body = Self.pseudoRandomBytes(count: 300 * 1024)
        // Not a multiple of the 64 KiB chunk, so the offset lands mid-chunk.
        let offset = 123_457

        try await Self.withLitter(fs, [path]) {
            // The interrupted upload: only the head arrived.
            try await Self.write(fs, path: path, content: body.prefix(offset))
            let partial = try await fs.stat(path: path)
            #expect(partial.size == UInt64(offset), "the partial upload has the wrong length")

            // The resume the backend refuses, then the restart it offers.
            let tail = Data(body.suffix(from: offset))
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.yield(tail)
            continuation.finish()
            let refusal: RemoteFSError?
            do {
                try await fs.write(path: path, mode: .append, contents: stream)
                refusal = nil
            } catch let error as RemoteFSError {
                refusal = error
            }
            #expect(refusal == .finding(.resumeNotSupported), "an appended upload was not refused")
            #expect(fs.supportsAppendResume == false)
            #expect(
                try await fs.stat(path: path).size == UInt64(offset),
                "a refused append changed the remote file")

            try await Self.write(fs, path: path, content: body)
            #expect(try await fs.stat(path: path).size == UInt64(body.count))
            let whole = try await Self.drain(try await fs.readStream(path: path))
            #expect(whole == body, "the restarted upload differs from its source")

            // The download resume: head, then the tail from the offset.
            let head = Data(whole.prefix(offset))
            let resumed = try await Self.drain(
                try await fs.readStream(path: path, fromOffset: UInt64(offset)))
            #expect(resumed == tail, "the bytes after REST differ from the tail")
            #expect(head + resumed == body, "head and resumed tail do not rebuild the file")

            // An offset at the end is an empty stream, not an error.
            let atEnd = try await Self.drain(
                try await fs.readStream(path: path, fromOffset: UInt64(body.count)))
            #expect(atEnd.isEmpty)
        }
    }

    // MARK: - Listing

    /// What the rig's daemon actually writes for a directory, read three ways
    /// and required to agree: the file system's own `list`, the raw `MLSD`
    /// run through `FTPListParser.mlsd`, and the raw `LIST` run through
    /// `FTPListParser.list`. The directory is the session root, which carries
    /// a file, a folder, and two symlinks (one to each) that the entrypoint
    /// creates — symlinks being the entry whose spelling differs most between
    /// servers and the one `PermissionsTreeApplier`'s safety rests on
    /// (`docs/BACKLOG.md`, the row whose title begins "An FTP server's MLSD
    /// symlink spelling is unmeasured").
    ///
    /// **The daemon advertises `MLST`, not `MLSD`.** RFC 3659 section 7.8
    /// makes `MLST` the feature name (the line that carries the fact list) and
    /// says a server that supports it also supports `MLSD`; ProFTPD, the only
    /// server measured here, never writes an `MLSD` line in `FEAT`.
    /// `list(path:)` once asked `features.contains("MLSD")` and so, against
    /// this daemon, ran `LIST` on every listing and never `MLSD` — and the
    /// loopback server could not have said so, because it wrote the
    /// non-standard `MLSD` line itself. The first assertion below is the one
    /// that failed on 2026-11-09.
    @Test func theRigDaemonsListingAgreesWithTheMLSDParser() async throws {
        let fs = try await Self.connect(port: Daemon.withMLSD.port)
        try await Self.withLitter(fs, []) {
            let connection = try await fs.pool.command()
            let features = await connection.features
            #expect(features.contains("MLSD"), "the daemon's MLST was not read as MLSD")

            let viaList = try await fs.list(path: "/")
            let viaMLSD = try FTPListParser.mlsd(
                try await Self.rawListing("MLSD", on: connection), at: "/")
            let viaLIST = try FTPListParser.list(
                try await Self.rawListing("LIST", on: connection), at: "/")

            for name in ["hello.txt", "sub", "link-to-hello", "link-to-sub"] {
                for (label, items) in [("list", viaList), ("MLSD", viaMLSD), ("LIST", viaLIST)] {
                    #expect(items.contains { $0.name == name }, "\(label) lost \(name)")
                }
            }

            // The seeded entries agree across the readers on what matters:
            // the kind and, for a file, the size. Compared by name, because
            // two daemons need not order a directory alike.
            for name in ["hello.txt", "sub", "link-to-hello", "link-to-sub"] {
                let kinds = [viaList, viaMLSD, viaLIST].map { items in
                    items.first { $0.name == name }?.kind
                }
                #expect(Set(kinds.map { $0.map(String.init(describing:)) ?? "nil" }).count == 1,
                    "the readers disagree on the kind of \(name): \(kinds)")
            }
            let hello = viaMLSD.first { $0.name == "hello.txt" }
            #expect(hello?.kind == .file)
            #expect(hello?.size == 30)
            #expect(hello?.permissions == 0o644)
            #expect(viaMLSD.first { $0.name == "sub" }?.kind == .directory)
            // The list the file system returned is the MLSD one: every item
            // equal to the MLSD parse of the same directory, `modified`
            // included. Compared in name order, because two reads of a
            // directory need not come back in the same one. (Withdrawn
            // wording of the check, verbatim: `viaList.map(\.name).sorted()
            // == viaMLSD.map(\.name).sorted()`, which `LIST` would also have
            // satisfied.)
            let byName: (RemoteFileItem, RemoteFileItem) -> Bool = { $0.name < $1.name }
            #expect(viaList.sorted(by: byName) == viaMLSD.sorted(by: byName))

            // Debt three: the daemon's spelling of a symlink is read as one,
            // by BOTH dialects. `.other` here would be chmodded by
            // `PermissionsTreeApplier`.
            for name in ["link-to-hello", "link-to-sub"] {
                #expect(viaMLSD.first { $0.name == name }?.kind == .symlink, "MLSD: \(name)")
                #expect(viaLIST.first { $0.name == name }?.kind == .symlink, "LIST: \(name)")
                #expect(viaList.first { $0.name == name }?.kind == .symlink, "list: \(name)")
            }
            // And nothing in the listing is `.other`.
            #expect(viaMLSD.allSatisfy { $0.kind != .other })
            #expect(viaLIST.allSatisfy { $0.kind != .other })
        }
    }

    /// The daemon that does not advertise `MLSD` really does not: `FEAT` is
    /// without it, the command is refused, and `list` still returns the whole
    /// directory — through `LIST`, which is the point of the second service.
    @Test func theDaemonWithoutMLSDListsThroughLIST() async throws {
        let fs = try await Self.connect(port: Daemon.withoutMLSD.port)
        try await Self.withLitter(fs, []) {
            let connection = try await fs.pool.command()
            let features = await connection.features
            #expect(features.contains("MLSD") == false)
            #expect(features.contains("MLST") == false)

            let refused: Bool
            do {
                _ = try await Self.rawListing("MLSD", on: connection)
                refused = false
            } catch {
                refused = true
            }
            #expect(refused, "the daemon without MLSD accepted an MLSD")

            let listed = try await fs.list(path: "/")
            let names = Set(listed.map(\.name))
            #expect(names.isSuperset(of: ["hello.txt", "sub", "link-to-hello", "link-to-sub"]))
            #expect(listed.first { $0.name == "hello.txt" }?.size == 30)
            #expect(listed.first { $0.name == "link-to-sub" }?.kind == .symlink)
            #expect(listed.allSatisfy { $0.kind != .other })
        }
    }

    /// The raw lines of a listing command on the COMMAND connection, the way
    /// `FTPFileSystem.list` runs it.
    private static func rawListing(
        _ verb: String, on connection: FTPControlConnection
    ) async throws -> [Data] {
        let sink = FTPListingSink()
        try await FTPDataConnection.transfer(verb, argument: "/", on: connection) { channel in
            try await channel.read { chunk in sink.append(chunk) }
        }
        return sink.lines()
    }
}
