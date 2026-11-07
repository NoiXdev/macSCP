import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The `RemoteFileSystem` conformance: which command each operation is, which
/// connection it runs on, and the one decision this task owns —
/// `supportsAppendResume`.
///
/// **Nothing here puts a credential, a host or a fingerprint where a reader
/// can reach it.** `#expect` prints the source text of its expression AND
/// what its subexpressions evaluated to, so a carrier never appears as an
/// operand — not in the negative check and not in the positive one standing
/// beside it, which is the half that is easy to miss: a positive check whose
/// spelling mentions no secret still prints the whole rendered value on a red
/// run. Every such comparison is computed into a named `Bool` first.
///
/// `.timeLimit(.minutes(5))` because cases here call `pollUntil`, which
/// carries no deadline of its own (`PollingGuardTests`).
@Suite("FTP file system", .timeLimit(.minutes(5)))
struct FTPFileSystemTests {
    // MARK: - Helpers

    private static func running<T: Sendable>(
        _ server: LoopbackFTPServer,
        _ body: (_ host: String, _ port: Int) async throws -> T
    ) async throws -> T {
        let endpoint = try await server.start()
        do {
            let result = try await body(endpoint.host, endpoint.port)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    /// A connected file system against the loopback server.
    ///
    /// The password travels in the CONFIG and nowhere else, which is the
    /// shape the app's own path produces (`FTPFieldSchema.makeConfig` puts
    /// the secret there) and the thing
    /// `thePasswordIsReadFromTheConfigAndNowhereElse` is about.
    ///
    /// `account` defaults to a fresh user name per call because
    /// `FTPPoolBudget` is process-wide by design (spec §5a) and two cases
    /// sharing an account would share a refusal count — the reason
    /// `FTPConnectionPoolTests.pool` does the same. The loopback server
    /// accepts only its own generated user name, so an overridden account is
    /// for the cases that expect a refused login.
    private static func connect(
        _ server: LoopbackFTPServer, host: String, port: Int,
        slots: Int = 1, initialPath: String? = nil,
        account: String? = nil, password: String? = nil,
        trustStore: TrustedCertificateStore? = nil,
        security: FTPSecurityMode = .plain
    ) async throws -> FTPFileSystem {
        let credentials = server.credentials
        return try await FTPFileSystem.connect(
            FTPConnectionConfig(
                host: host, port: port, username: account ?? credentials.username,
                security: security, initialPath: initialPath,
                password: password ?? credentials.password),
            transferSlots: slots,
            certificateDecider: .refusing,
            timeout: .seconds(30),
            trustStore: trustStore)
    }

    private static func verbs(_ server: LoopbackFTPServer) async -> [String] {
        await server.receivedCommands.map(\.verb)
    }

    /// The payload a chunk stream carries, as a stream.
    private static func stream(_ payload: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(payload)
            continuation.finish()
        }
    }

    private enum Outcome: Equatable, CustomStringConvertible {
        case ok
        case remote(RemoteFSError)
        case ftp(FTPConnectionFailure)
        case other(String)

        var description: String {
            switch self {
            case .ok: "ok"
            case .remote(let error): "remote(\(error))"
            case .ftp(let failure): "ftp(\(failure))"
            case .other(let type): "other(\(type))"
            }
        }
    }

    private static func outcome(of work: () async throws -> Void) async -> Outcome {
        do {
            try await work()
            return .ok
        } catch let error as RemoteFSError {
            return .remote(error)
        } catch let failure as FTPConnectionFailure {
            return .ftp(failure)
        } catch {
            return .other(String(describing: type(of: error)))
        }
    }

    // MARK: - Listing

    /// `MLSD` when `FEAT` advertises it, `LIST` when it does not — and the
    /// SAME items either way, which is the property that makes the fallback a
    /// fallback rather than a second behaviour.
    ///
    /// Both halves are positive and both are negative: each server is checked
    /// for the verb it should have sent AND for the absence of the other, so a
    /// backend that sent both would fail, and one that read `FEAT` the wrong
    /// way round would fail on the verb rather than on the items.
    @Test func listPrefersMLSDWhenFEATAdvertisesItAndFallsBackToLIST() async throws {
        func listing(advertisesMLSD: Bool) async throws -> (
            items: [RemoteFileItem], verbs: [String]
        ) {
            let server = LoopbackFTPServer(
                security: .plain, advertisesMLSD: advertisesMLSD, requiresTLSSessionReuse: false)
            await server.seedFile("/pub/one.txt", contents: Data("hello".utf8))
            await server.seedFile("/pub/deep/two.txt", contents: Data("x".utf8))
            let items = try await Self.running(server) { host, port in
                let fs = try await Self.connect(server, host: host, port: port)
                let items = try await fs.list(path: "/pub")
                await fs.disconnect()
                return items
            }
            return (items, await Self.verbs(server))
        }

        let modern = try await listing(advertisesMLSD: true)
        #expect(modern.verbs.contains("MLSD"))
        #expect(!modern.verbs.contains("LIST"))

        let legacy = try await listing(advertisesMLSD: false)
        #expect(legacy.verbs.contains("LIST"))
        #expect(!legacy.verbs.contains("MLSD"))

        for listing in [modern, legacy] {
            #expect(listing.items.map(\.name).sorted() == ["deep", "one.txt"])
            let file = listing.items.first { $0.name == "one.txt" }
            #expect(file?.kind == .file)
            #expect(file?.size == 5)
            #expect(file?.path == "/pub/one.txt")
            #expect(listing.items.first { $0.name == "deep" }?.kind == .directory)
        }
    }

    /// A line in no dialect the reader knows fails THAT DIRECTORY and names
    /// the line, counted from 1.
    ///
    /// The whole directory rather than the readable part of it: a listing
    /// shown with entries silently missing is what a comparison or a sync
    /// would then act on (`FTPListParser`'s own argument). The line NUMBER is
    /// the actionable part — a thousand-line listing with one bad line is
    /// otherwise a folder that refuses to open for no stated reason — and it
    /// is the position and never the line, because the line is the server's
    /// text and a file name is in it.
    @Test func anUnreadableListingLineFailsThatDirectoryAndNamesTheLine() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: false, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/one.txt", contents: Data("hello".utf8))
        let outcome = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            // Line 1 is readable Unix `LIST`, line 2 is in no dialect.
            await server.answerNextListingWith(
                Data(
                    """
                    -rw-r--r--   1 ftp      ftp             5 Jan  1  2026 one.txt\r
                    this line is not a listing in any dialect\r

                    """.utf8))
            let outcome = await Self.outcome { _ = try await fs.list(path: "/pub") }
            await fs.disconnect()
            return outcome
        }
        #expect(outcome == .remote(.finding(.listingLineUnreadable(line: 2))))

        // The positive beside it: the same listing WITHOUT the bad line is
        // read, so the refusal above is the bad line's doing and not a
        // listing path that refuses everything.
        let second = LoopbackFTPServer(
            security: .plain, advertisesMLSD: false, requiresTLSSessionReuse: false)
        await second.seedFile("/pub/one.txt", contents: Data("hello".utf8))
        let names = try await Self.running(second) { host, port in
            let fs = try await Self.connect(second, host: host, port: port)
            await second.answerNextListingWith(
                Data("-rw-r--r--   1 ftp      ftp             5 Jan  1  2026 one.txt\r\n".utf8))
            let items = try await fs.list(path: "/pub")
            await fs.disconnect()
            return items.map(\.name)
        }
        #expect(names == ["one.txt"])
    }

    // MARK: - One entry

    /// `stat` of a file is `SIZE` and `MDTM` and no data connection at all.
    ///
    /// The question `TransferEngine` asks before every transfer, so its cost
    /// is the point: two commands on the reserved connection, where the
    /// alternative — listing the parent — is a passive negotiation and a
    /// socket per file.
    @Test func statOfAFileReadsMDTMAndSIZEWhenAdvertised() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        // A fixed instant, so the assertion is an equality and not a window:
        // 2026-03-04 05:06:07 UTC.
        let stamp = Date(timeIntervalSince1970: 1_772_600_767)
        await server.seedFile("/pub/one.txt", contents: Data("hello".utf8), modifiedAt: stamp)
        let entry = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            let entry = try await fs.stat(path: "/pub/one.txt")
            await fs.disconnect()
            return entry
        }
        #expect(entry.kind == .file)
        #expect(entry.size == 5)
        #expect(entry.name == "one.txt")
        // Exactly: the seeded instant is a whole number of seconds, which is
        // all `MDTM` can carry (`YYYYMMDDHHMMSS`, no fraction).
        #expect(entry.modifiedAt == stamp)

        let verbs = await Self.verbs(server)
        #expect(verbs.contains("SIZE"))
        #expect(verbs.contains("MDTM"))
        // The negative that gives the case its point: no listing was needed,
        // so no data connection was opened for it.
        #expect(!verbs.contains("MLSD"))
        #expect(!verbs.contains("LIST"))
        #expect(!verbs.contains("PASV"))
        #expect(!verbs.contains("EPSV"))
    }

    /// A DIRECTORY is not answered by `SIZE`, so `stat` falls through to the
    /// parent listing — which is also the only thing that answers the kind,
    /// the permission bits and the owner.
    @Test func statOfADirectoryFallsThroughToTheParentListing() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/deep/two.txt", contents: Data("x".utf8))
        let result = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            let entry = try await fs.stat(path: "/pub/deep")
            let root = try await fs.stat(path: "/")
            let missing = await Self.outcome { _ = try await fs.stat(path: "/pub/nothing") }
            await fs.disconnect()
            return (entry: entry, root: root, missing: missing)
        }
        #expect(result.entry.kind == .directory)
        #expect(result.entry.path == "/pub/deep")
        // The root needs no round trip and has no parent to be listed from.
        #expect(result.root.kind == .directory)
        #expect(result.root.path == "/")
        #expect(result.missing == .remote(.notFound(path: "/pub/nothing")))
    }

    // MARK: - Writing

    /// `STOR`, on a POOLED connection taken through a lease, and the lease
    /// comes back.
    ///
    /// The release is the half spec §5a is about: a pooled connection is held
    /// by the transfer and one leak per upload ends in a permanently starved
    /// pool. Read off the pool's own free count, which is the only place that
    /// property is visible, and waited for on STATE rather than on a clock.
    @Test func writeSendsSTORThroughATransferLease() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/placeholder", contents: Data())
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let free = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port, slots: 1)
            try await fs.write(
                path: "/pub/upload.bin", mode: .overwrite, contents: Self.stream(payload))
            try await pollUntil("the upload's lease to go back to the pool") {
                await fs.pool.freeTransferSlots == 1
            }
            let free = await fs.pool.freeTransferSlots
            await fs.disconnect()
            return free
        }
        #expect(free == 1)
        #expect(await server.contents(of: "/pub/upload.bin") == payload)

        let verbs = await Self.verbs(server)
        #expect(verbs.contains("STOR"))
        // Two control connections: the reserved command one and the pooled
        // transfer one. The STOR did not run on the command connection.
        #expect(await server.controlConnectionCount == 2)
    }

    /// A download reads through a lease too, and an offset becomes `REST`.
    @Test func readStreamResumesWithRESTAndReturnsItsLease() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let payload = Data("0123456789".utf8)
        await server.seedFile("/pub/one.bin", contents: payload)
        let read = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port, slots: 1)
            var tail = Data()
            for try await chunk in try await fs.readStream(path: "/pub/one.bin", fromOffset: 4) {
                tail.append(chunk)
            }
            try await pollUntil("the download's lease to go back to the pool") {
                await fs.pool.freeTransferSlots == 1
            }
            await fs.disconnect()
            return tail
        }
        #expect(read == Data("456789".utf8))
        let commands = await server.receivedCommands
        #expect(commands.contains { $0.verb == "REST" && $0.argument == "4" })
        #expect(commands.contains { $0.verb == "RETR" })
    }

    // MARK: - supportsAppendResume

    /// **The decision this task owns, and its evidence.**
    ///
    /// An append-resume onto a destination that was REPLACED while the
    /// transfer was broken splices two files: the tail of the new one onto
    /// the head of the old, a file of exactly the right length and entirely
    /// wrong contents, which nothing downstream can notice.
    ///
    /// The spec offered a substitute for the validator FTP has not got: size
    /// plus `MDTM` before the `REST`. This case measures why that cannot be
    /// built. `SIZE` reads the SAME number for the partial file and for an
    /// equal-length replacement — the first two expectations — and `MDTM` has
    /// nothing to be compared against, because `TransferEngine` takes the
    /// resume offset from `destination.stat(path:).size` and carries no
    /// destination validator between attempts. So the check reduces to "the
    /// destination is as long as I believe I wrote", which the replacement
    /// satisfies.
    ///
    /// `supportsAppendResume` is therefore `false`, `write(…mode: .append…)`
    /// refuses, and the remote file is left as the replacement rather than as
    /// a splice. Both are asserted here: the refusal, and the bytes.
    @Test func aResumedUploadOntoAReplacedRemoteFileDoesNotProduceASplicedFile() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let partial = Data("AAAAAAAAAA".utf8)      // what an interrupted upload left
        let replacement = Data("BBBBBBBBBB".utf8)  // a different file, the same length
        let tail = Data("CCCCC".utf8)              // what a resume would append
        #expect(partial.count == replacement.count)
        await server.seedFile("/pub/half.bin", contents: partial)

        let measured = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port, slots: 1)
            let beforeReplacement = try await fs.stat(path: "/pub/half.bin").size
            await server.seedFile("/pub/half.bin", contents: replacement)
            let afterReplacement = try await fs.stat(path: "/pub/half.bin").size
            let refusal = await Self.outcome {
                try await fs.write(
                    path: "/pub/half.bin", mode: .append, contents: Self.stream(tail))
            }
            let appendable = fs.supportsAppendResume
            await fs.disconnect()
            return (
                before: beforeReplacement, after: afterReplacement, refusal: refusal,
                appendable: appendable
            )
        }

        // The blind spot: the only reading available before a `REST` cannot
        // tell the partial file from the replacement.
        #expect(measured.before == 10)
        #expect(measured.after == measured.before)
        // So resumption is off, and the append is refused.
        #expect(measured.appendable == false)
        #expect(measured.refusal == .remote(.finding(.resumeNotSupported)))
        // And the remote file is the replacement, not a splice. Compared
        // against the replacement AND against the splice it would have been,
        // because equality with the replacement alone also holds for a write
        // that failed in some other way after truncating nothing.
        #expect(await server.contents(of: "/pub/half.bin") == replacement)
        #expect(await server.contents(of: "/pub/half.bin") != replacement + tail)
        #expect(await server.contents(of: "/pub/half.bin") != partial + tail)
        // The negative that says the refusal happened BEFORE the wire: no
        // transfer was started for it.
        #expect(!(await Self.verbs(server)).contains("STOR"))
    }

    // MARK: - Mutations

    @Test func deleteUsesDELEAndDeleteTreeDescendsWithRMD() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/one.txt", contents: Data("a".utf8))
        await server.seedFile("/pub/tree/two.txt", contents: Data("b".utf8))
        await server.seedFile("/pub/tree/deeper/three.txt", contents: Data("c".utf8))

        let outcomes = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            try await fs.delete(path: "/pub/one.txt")
            let onAFolder = await Self.outcome { try await fs.delete(path: "/pub/tree") }
            let onNothing = await Self.outcome { try await fs.delete(path: "/pub/gone.txt") }
            try await fs.deleteTree(at: "/pub/tree")
            let remaining = try await fs.list(path: "/pub")
            await fs.disconnect()
            return (onAFolder: onAFolder, onNothing: onNothing, remaining: remaining)
        }

        #expect(outcomes.remaining.isEmpty)
        #expect(outcomes.onNothing == .remote(.notFound(path: "/pub/gone.txt")))
        // A directory is its own refusal and not "not found", because the two
        // are different things to a caller and FTP answers `550` to both.
        if case .remote(.protocolError) = outcomes.onAFolder {
        } else {
            Issue.record("expected a protocolError for a folder, got \(outcomes.onAFolder)")
        }

        let commands = await server.receivedCommands
        #expect(commands.contains { $0.verb == "DELE" && $0.argument == "/pub/one.txt" })
        // Deepest first, because `RMD` removes an EMPTY directory only.
        let removals = commands.filter { $0.verb == "RMD" }.map(\.argument)
        #expect(removals == ["/pub/tree/deeper", "/pub/tree"])
        #expect(await server.contents(of: "/pub/tree/deeper/three.txt") == nil)
    }

    @Test func renameSendsRNFRThenRNTO() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/old.txt", contents: Data("payload".utf8))
        await server.seedFile("/pub/taken.txt", contents: Data("mine".utf8))

        let occupied = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            try await fs.rename(from: "/pub/old.txt", to: "/pub/new.txt")
            let occupied = await Self.outcome {
                try await fs.rename(from: "/pub/new.txt", to: "/pub/taken.txt")
            }
            await fs.disconnect()
            return occupied
        }

        #expect(await server.contents(of: "/pub/new.txt") == Data("payload".utf8))
        #expect(await server.contents(of: "/pub/old.txt") == nil)
        // The occupied destination is refused by THIS client, before `RNFR`:
        // several real servers overwrite it without a word, and the contract
        // says a rename never silently overwrites.
        #expect(occupied == .remote(.finding(.directoryAlreadyExists)))
        #expect(await server.contents(of: "/pub/taken.txt") == Data("mine".utf8))

        let verbs = await Self.verbs(server)
        let rnfr = verbs.firstIndex(of: "RNFR")
        let rnto = verbs.firstIndex(of: "RNTO")
        #expect(rnfr != nil)
        #expect(rnto != nil)
        // In that order, and exactly once each: the refused second rename
        // never reached the wire.
        #expect((rnfr ?? .max) < (rnto ?? 0))
        #expect(verbs.filter { $0 == "RNFR" }.count == 1)
        #expect(verbs.filter { $0 == "RNTO" }.count == 1)
    }

    @Test func createDirectorySendsMKD() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/file.txt", contents: Data("a".utf8))

        let inTheWay = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            try await fs.createDirectory(at: "/pub/fresh")
            // Idempotent: the contract says a second call returns silently.
            try await fs.createDirectory(at: "/pub/fresh")
            let inTheWay = await Self.outcome {
                try await fs.createDirectory(at: "/pub/file.txt")
            }
            await fs.disconnect()
            return inTheWay
        }

        #expect(inTheWay == .remote(.finding(.pathExistsAndIsNotADirectory(path: "/pub/file.txt"))))
        let commands = await server.receivedCommands
        #expect(commands.filter { $0.verb == "MKD" }.map(\.argument)
            == ["/pub/fresh", "/pub/fresh", "/pub/file.txt"])
    }

    /// `SITE CHMOD`, and a refusal that is this FILE's rather than the
    /// connection's.
    ///
    /// Per-file in both senses the name carries: it is reported as a
    /// `RemoteFSError` about that path, and the connection is still answering
    /// afterwards — which the second half asserts by using it again. A
    /// refusal that took the session down would be a `SITE CHMOD` nobody
    /// could offer in a browser.
    @Test func setPermissionsSendsSITECHMODAndSurfacesARefusalAsAPerFileError() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/file.txt", contents: Data("a".utf8))

        let result = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            // The file-type bits are masked off, as the contract says.
            try await fs.setPermissions(path: "/pub/file.txt", permissions: 0o100_644)
            await server.refuseNextSiteChmodWith550()
            let refused = await Self.outcome {
                try await fs.setPermissions(path: "/pub/file.txt", permissions: 0o600)
            }
            // The connection is in step: the server answered, so the next
            // command is read against itself.
            let stillUsable = try await fs.stat(path: "/pub/file.txt").size
            await fs.disconnect()
            return (refused: refused, stillUsable: stillUsable)
        }

        #expect(result.refused == .remote(.permissionDenied(path: "/pub/file.txt")))
        #expect(result.stillUsable == 1)
        let sites = await server.receivedCommands.filter { $0.verb == "SITE" }.map(\.argument)
        #expect(sites == ["CHMOD 644 /pub/file.txt", "CHMOD 600 /pub/file.txt"])
    }

    // MARK: - The session

    @Test func homeDirectoryPathReadsPWDAfterLogin() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let home = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            let home = try await fs.homeDirectoryPath()
            await fs.disconnect()
            return home
        }
        #expect(home == "/")
        #expect(await Self.verbs(server).contains("PWD"))
    }

    /// `FTPConnectionConfig.initialPath` — "the folder to open first" — is
    /// read, and this is the one thing that reads it.
    ///
    /// It answers without `PWD`, which is the negative half: a landing folder
    /// the user named is not a question for the server.
    @Test func anInitialPathIsWhereTheSessionOpensAndNeedsNoPWD() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/one.txt", contents: Data("a".utf8))
        let home = try await Self.running(server) { host, port in
            let fs = try await Self.connect(
                server, host: host, port: port, initialPath: "/pub/")
            let home = try await fs.homeDirectoryPath()
            await fs.disconnect()
            return home
        }
        #expect(home == "/pub")
        #expect(!(await Self.verbs(server)).contains("PWD"))
    }

    /// `PWD`'s reply is a QUOTED path, and a quote inside it is doubled
    /// (RFC 959 section 4.2). Read off the parser directly: a path with a
    /// quote in it cannot be seeded through this server's own `resolve`.
    @Test func aQuotedPWDReplyIsReadIncludingItsDoubledQuotes() {
        #expect(FTPFileSystem.quotedPath(in: "\"/home/tim\" is the current directory") == "/home/tim")
        #expect(FTPFileSystem.quotedPath(in: "\"/a \"\"b\"\" c\" is it") == "/a \"b\" c")
        #expect(FTPFileSystem.quotedPath(in: "no quotes here") == nil)
    }

    @Test func checksumAnswersUnavailableOnThisConnection() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/one.txt", contents: Data("a".utf8))
        let outcome = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            // Reached the way a caller reaches it: through the protocol
            // existential and an `as?`, which is what a surface that offers
            // the menu entry does.
            let connection: any RemoteFileSystem = fs
            let provider = try #require(connection as? any RemoteChecksumProvider)
            let outcome = try await provider.remoteChecksum(
                forFileAt: "/pub/one.txt", algorithm: .sha256)
            await fs.disconnect()
            return outcome
        }
        #expect(outcome == .unavailableOnThisConnection)
        // The answer costs no round trip: nothing FTP can send turns it into
        // a checksum, so spending one would only make the same answer slower.
        #expect(!(await Self.verbs(server)).contains("SITE"))
    }

    // MARK: - The password, and what a failure may carry

    /// The password is read from the CONFIG and nothing else supplies it.
    ///
    /// `FTPConnectionConfig.password` had no reader anywhere before this
    /// file — the shape this plan has already produced once — and
    /// `FTPControlConnection.connect` takes the credential as a separate
    /// argument. So "which of the two does the conformance use" is a real
    /// question, and the answer is measured here rather than claimed: a
    /// config carrying the server's password logs in, and one carrying
    /// something else is refused.
    ///
    /// **Neither password is an operand of any expectation.** Both are in
    /// named constants and both verdicts are `Bool`s computed before the
    /// `#expect`, including the positive one: `#expect(outcome == .ok)` would
    /// be safe, but `#expect(outcome == ...)` on an outcome that CARRIED the
    /// credential would not, and the rule is about the shape rather than
    /// about this instance.
    @Test func thePasswordIsReadFromTheConfigAndNowhereElse() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let right = server.credentials.password
        let wrong = "not-the-password-" + UUID().uuidString

        let outcomes = try await Self.running(server) { host, port in
            let accepted = await Self.outcome {
                let fs = try await Self.connect(
                    server, host: host, port: port, password: right)
                await fs.disconnect()
            }
            let refused = await Self.outcome {
                let fs = try await Self.connect(
                    server, host: host, port: port, password: wrong)
                await fs.disconnect()
            }
            return (accepted: accepted, refused: refused)
        }

        let theRightPasswordLoggedIn = outcomes.accepted == .ok
        let theWrongPasswordDidNot =
            outcomes.refused
            == .remote(.connectionFailed(reason: CoreL10n.string("core.connect.authFailed")))
        #expect(theRightPasswordLoggedIn)
        #expect(theWrongPasswordDidNot)

        // The server never saw either password in a loggable place: its own
        // record redacts `PASS`. A positive control beside it, so a record
        // that stopped recording arguments at all would not read as clean.
        let passwordArguments = await server.receivedCommands
            .filter { $0.verb == "PASS" }.map(\.argument)
        let everyPasswordIsRedacted = passwordArguments.allSatisfy {
            $0 == LoopbackFTPReceivedCommand.redactedArgument
        }
        #expect(everyPasswordIsRedacted)
        #expect(passwordArguments.count == 2)
    }

    /// A pinned certificate that changed reaches the file system as a
    /// sentence that carries NO fingerprint, no host and no port.
    ///
    /// The hard stop itself is `FTPControlConnection`'s and is measured there
    /// (`aPinnedCertificateThatChangedIsAHardStopWithNoPrompt`). What is new
    /// here is the SURFACE: `connect` turns an `FTPConnectionFailure` into a
    /// `RemoteFSError.connectionFailed(reason:)`, and a `reason` is a string
    /// that travels — into an alert, into the diagnostic log, into whatever a
    /// user pastes into a public issue.
    ///
    /// **Every carrier is in a named constant and every verdict is a `Bool`
    /// computed before its expectation**, the positive one included: `reason`
    /// is the value under test, so `#expect(reason == …)` would print the
    /// whole rendered sentence on a red run, which is exactly the thing being
    /// checked for carriers.
    @Test func aMismatchedCertificateSurfacesWithNoFingerprintInItsSentence() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftpfs-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)
        let pinnedFingerprint = Data("not this server's certificate".utf8).base64EncodedString()

        let measured = try await Self.running(server) { host, port in
            try store.upsert(
                TrustedCertificate(
                    host: host, port: port, derBase64: pinnedFingerprint,
                    subject: "pinned", issuer: "pinned", notAfter: nil))
            let outcome = await Self.outcome {
                let fs = try await Self.connect(
                    server, host: host, port: port, trustStore: store, security: .implicitTLS)
                await fs.disconnect()
            }
            var reason = ""
            if case .remote(.connectionFailed(let text)) = outcome { reason = text }
            let carriers = [host, String(port), pinnedFingerprint]
            return (
                isTheMismatchSentence: reason
                    == CoreL10n.string("core.connect.ftpCertificateMismatch"),
                isNotTheKeyItself: reason != "core.connect.ftpCertificateMismatch",
                carriesNoCarrier: carriers.allSatisfy { !reason.contains($0) },
                isEmpty: reason.isEmpty
            )
        }

        #expect(measured.carriesNoCarrier)
        // The positives beside it: an empty sentence also carries no
        // fingerprint, and a key no catalogue declares comes back as itself.
        #expect(measured.isTheMismatchSentence)
        #expect(measured.isNotTheKeyItself)
        #expect(measured.isEmpty == false)
    }
}
