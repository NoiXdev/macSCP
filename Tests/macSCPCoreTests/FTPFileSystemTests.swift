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

    // MARK: - What the queue reads off a failed transfer

    /// A download the connection DROPPED is a connection failure, so the
    /// transfer queue keeps the job and resumes it; a transfer the server
    /// REFUSED is not, so the queue fails it.
    ///
    /// **This is classification in Core, not rendering in the App.**
    /// `TransferQueueViewModel.swift:1340` —
    /// `catch let error as RemoteFSError where error.isConnectionFailure` — is
    /// the only path to `.interrupted` with the job retained for
    /// `retryInterrupted`, and the only call site of `isConnectionFailure` in
    /// `Sources`. Everything else falls to the generic catch and the job is
    /// dropped. So an `FTPConnectionFailure` leaving this backend uncon­verted
    /// costs the user a download that FTP can demonstrably resume (`REST`
    /// before `RETR`, which `readStreamResumesWithRESTAndReturnsItsLease`
    /// asserts) onto a local destination that answers
    /// `supportsAppendResume == true`.
    ///
    /// The split is read off `FTPConnectionFailure.leavesConnectionInStep`,
    /// which already exists and is already tested: a failure that leaves the
    /// connection OUT of step is one nothing established the state of — the
    /// connection ended — and that is exactly a connection failure. One the
    /// server ANSWERED is a refusal, and converting it would assert
    /// `isConnectionFailure == true` about something a retry meets again.
    ///
    /// Both halves here, because the `true` alone would hold for a backend
    /// that called everything a connection failure.
    @Test func aDroppedDownloadIsAConnectionFailureAndARefusalIsNot() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/big.bin", contents: Data(repeating: 0x41, count: 256 * 1024))

        let dropped = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port, slots: 1)
            await server.dropControlConnectionMidTransfer()
            let outcome = await Self.outcome {
                for try await _ in try await fs.readStream(path: "/pub/big.bin", fromOffset: 0) {}
            }
            await fs.disconnect()
            return outcome
        }
        let droppedReadsAsAConnectionFailure: Bool
        if case .remote(let error) = dropped { droppedReadsAsAConnectionFailure = error.isConnectionFailure }
        else { droppedReadsAsAConnectionFailure = false }
        #expect(droppedReadsAsAConnectionFailure, "\(dropped)")

        // The other half, on a fresh server because the first one's control
        // connection is gone: a `550` is the server answering, so it is
        // `notFound` and NOT a connection failure. That also closes the
        // inconsistency where `stat` and `delete` mapped `550` and a transfer
        // did not.
        let second = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await second.seedFile("/pub/present.bin", contents: Data("x".utf8))
        let refused = try await Self.running(second) { host, port in
            let fs = try await Self.connect(second, host: host, port: port, slots: 1)
            let outcome = await Self.outcome {
                for try await _ in try await fs.readStream(path: "/pub/gone.bin", fromOffset: 0) {}
            }
            await fs.disconnect()
            return outcome
        }
        #expect(refused == .remote(.notFound(path: "/pub/gone.bin")))
        let refusalReadsAsAConnectionFailure: Bool
        if case .remote(let error) = refused { refusalReadsAsAConnectionFailure = error.isConnectionFailure }
        else { refusalReadsAsAConnectionFailure = true }
        #expect(refusalReadsAsAConnectionFailure == false)
    }

    /// The §5a release invariant survives the error mapping above.
    ///
    /// Mapping a stream's terminal error means wrapping the lease's stream,
    /// and spec §5a is what that can break: `FTPTransferLease.readStream`
    /// releases the lease on every way the stream can end INCLUDING a
    /// consumer that stops iterating and drops it, and a pump TASK between
    /// the two streams would make dropping the outer one no longer terminate
    /// the inner one — one leak per abandoned download, and a permanently
    /// starved pool.
    ///
    /// The wrapper is therefore an unfolding stream with no task in it: its
    /// closure holds the inner stream's iterator, so releasing the outer
    /// releases the inner, whose own termination is what returns the lease.
    /// This case is what says so. `FTPConnectionPoolTests
    /// .anAbandonedReadStreamReturnsItsLeaseToThePool` measures the same
    /// property one layer down, on the lease itself.
    @Test func anAbandonedDownloadStillReturnsItsLeaseThroughTheMapping() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        // Big enough that one chunk is not the whole file, so the stream is
        // dropped with the transfer still running.
        await server.seedFile(
            "/pub/big.bin", contents: Data((0..<(512 * 1024)).map { UInt8($0 % 251) }))
        let free = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port, slots: 1)
            // A function, not a `do` block: the stream AND its iterator have
            // to go out of scope, and a block leaves both alive in the
            // enclosing scope (`FTPConnectionPoolTests.firstChunkThenDrop`).
            func firstChunkThenDrop() async throws -> Int {
                let stream = try await fs.readStream(path: "/pub/big.bin", fromOffset: 0)
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next()?.count ?? 0
            }
            let first = try await firstChunkThenDrop()
            try await pollUntil("the abandoned download's lease to go back to the pool") {
                await fs.pool.freeTransferSlots == 1
            }
            let free = await fs.pool.freeTransferSlots
            await fs.disconnect()
            return (first: first, free: free)
        }
        // The positive beside the release: a chunk really did arrive, so the
        // stream was abandoned mid-transfer rather than never started.
        #expect(free.first > 0)
        #expect(free.free == 1)
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

    /// The mask is the low TWELVE bits, not the low nine.
    ///
    /// Its own case because the one above cannot see the difference: its
    /// inputs are `0o100_644`, which masks to `0o644` under either width, and
    /// `0o600`. Measured by the review — `permissions & 0o7777` → `& 0o777`
    /// was GREEN against the whole suite, so the contract's "only the low 12
    /// bits (rwx for owner/group/other + setuid/setgid/sticky)" was held to
    /// nine of them.
    ///
    /// What a user feels under that plant: `0o4755 & 0o777 == 0o755`, so
    /// setting setuid, setgid or sticky silently drops the bit and
    /// `setPermissions` reports success. All three are checked, and the file
    /// type bits above them are checked to be dropped — the same contract
    /// says "file-type bits are never written".
    @Test func thePermissionMaskKeepsTheSpecialBitsAndDropsTheTypeBits() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/file.txt", contents: Data("a".utf8))
        try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            // setuid, setgid, sticky, all three at once, and a mode whose
            // file-type bits (0o100000, a regular file) must not be sent.
            for mode: UInt32 in [0o4755, 0o2755, 0o1777, 0o7000, 0o100_755] {
                try await fs.setPermissions(path: "/pub/file.txt", permissions: mode)
            }
            await fs.disconnect()
        }
        let sites = await server.receivedCommands.filter { $0.verb == "SITE" }.map(\.argument)
        #expect(sites == [
            "CHMOD 4755 /pub/file.txt",
            "CHMOD 2755 /pub/file.txt",
            "CHMOD 1777 /pub/file.txt",
            "CHMOD 7000 /pub/file.txt",
            "CHMOD 755 /pub/file.txt",
        ])
    }

    /// `deleteTree`'s COOPERATIVE cancellation: the `try
    /// Task.checkCancellation()` the method's own contract comment promises
    /// ("cooperatively cancellable per entry").
    ///
    /// Measured by the review as unmeasured — deleting all three checks from
    /// the file was GREEN — and below this project's own precedent, which is
    /// `HTTPTransferCancelTests
    /// .aTreeDeleteCancelledBeforeItsFirstBatchEndsInACancellation` for S3
    /// and `deleteTreeCancellationLeavesConsistentServerState` for SSH. The
    /// S3 case is a cancelled-before-its-first-request case, and so is this
    /// one, for a reason worth writing down.
    ///
    /// **On FTP the cooperative check is only observable while NO command is
    /// in flight, and that is a property of the transport rather than a
    /// choice here.** A cancellation that lands while a reply is outstanding
    /// ends the read instead: `readReply` iterates an `AsyncStream`, an
    /// iteration in a cancelled task ends at once with no element, and the
    /// connection reports `connectionClosed`. So a mid-walk cancel stops the
    /// walk whether the checks are there or not, and a case built on one
    /// could not tell the two apart — it would be the "tests that watch a
    /// defect heal" shape with the healing done by the transport.
    ///
    /// The one window with nothing in flight that a test can address from
    /// outside is before the first command, so the task is cancelled while it
    /// is still parked on a gate and then let go. `AsyncSignal.wait()`
    /// answers `.cancelled` at once for an already-cancelled task, so the
    /// body reaches `deleteTree` in a cancelled task deterministically —
    /// there is no clock here and no race.
    ///
    /// **Every postcondition is read before anything heals**: the outcome
    /// first, then the commands, then the files, with nothing restarted or
    /// retried in between. Nothing heals a cancelled `deleteTree` anyway —
    /// its contract says it leaves a partly deleted tree in place — which is
    /// the second half of what is asserted.
    @Test func aTreeDeleteCancelledBeforeItsFirstCommandEndsInACancellation() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile("/pub/tree/a.txt", contents: Data("a".utf8))
        await server.seedFile("/pub/tree/b.txt", contents: Data("b".utf8))
        await server.seedFile("/pub/tree/deeper/c.txt", contents: Data("c".utf8))

        let measured = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            // The commands the dial itself sent, so the sweep below counts
            // only what the delete sent.
            let beforeTheDelete = await server.receivedCommands.count
            let gate = AsyncSignal()
            let run = Task { try await fs.deleteTree(at: "/pub/tree") }
            run.cancel()
            gate.signal()
            let outcome = await Self.outcome { _ = try await run.value }
            // Read in this order, and nothing between them heals anything.
            let sent = await server.receivedCommands.dropFirst(beforeTheDelete).map(\.verb)
            let survivors = [
                await server.contents(of: "/pub/tree/a.txt"),
                await server.contents(of: "/pub/tree/b.txt"),
                await server.contents(of: "/pub/tree/deeper/c.txt"),
            ].compactMap { $0 }.count
            await fs.disconnect()
            return (outcome: outcome, sent: sent, survivors: survivors)
        }

        #expect(measured.outcome == .other("CancellationError"))
        // Nothing of the walk reached the wire. `NOOP` is the keepalive and
        // is not the delete's, so the sweep names the verbs the delete would
        // have sent rather than asserting an empty list.
        let walked = measured.sent.filter {
            ["SIZE", "MDTM", "MLSD", "LIST", "DELE", "RMD"].contains($0)
        }
        #expect(walked.isEmpty, "\(measured.sent)")
        // And the tree is whole, which is the half that says the cancellation
        // stopped a delete rather than merely reporting one.
        #expect(measured.survivors == 3)
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

    // MARK: - The permission editor, per connection

    /// The editor is offered per CONNECTION, which is Ruling R5 of the plan
    /// and the design's §14: `SITE CHMOD` is a per-server extension, so
    /// `.posixMode` is true of FTP and may be false of the server.
    ///
    /// Three answers, and the third is the one that makes the first two
    /// meaningful. A server that lists `CHMOD` in `SITE HELP` offers the
    /// editor; a server with no `SITE` at all does not; and the answer is
    /// asked ONCE, so a surface may ask per row.
    @Test func thePermissionEditorIsProbedOncePerConnection() async throws {
        let offering = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let offered = try await Self.running(offering) { host, port in
            let fs = try await Self.connect(offering, host: host, port: port)
            let first = await fs.offersPermissionEditing()
            let second = await fs.offersPermissionEditing()
            await fs.disconnect()
            return (first: first, second: second)
        }
        #expect(offered.first)
        #expect(offered.second)
        // Asked once: the second ask read the memory, not the wire.
        let helps = await offering.receivedCommands.filter {
            $0.verb == "SITE" && $0.argument.uppercased() == "HELP"
        }
        #expect(helps.count == 1)

        let bare = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false,
            offersSiteCommands: false)
        let refused = try await Self.running(bare) { host, port in
            let fs = try await Self.connect(bare, host: host, port: port)
            let answer = await fs.offersPermissionEditing()
            await fs.disconnect()
            return answer
        }
        #expect(refused == false)
    }

    /// Signal 1: a server that lists its `SITE` subcommands in `FEAT` is
    /// believed, and `SITE HELP` is never sent.
    ///
    /// The free signal, paid for by the dial, and the review measured it
    /// exercised by nothing — `$0.hasPrefix("SITE")` →
    /// `$0.hasPrefix("ZZZZNOSUCHFEATURE")` was GREEN. It could not have been
    /// otherwise: the fixture's `FEAT` was `UTF8`, `SIZE`, `MDTM` plus
    /// `MLST`/`MLSD`, so `thePermissionEditorIsProbedOncePerConnection`'s
    /// `helps.count == 1` was itself the proof that signal 1 never fired.
    ///
    /// The `FEAT` line is written as a real server writes it — the
    /// subcommands on one line, `SITE CHMOD UMASK` — which is why the probe
    /// matches a `SITE` PREFIX containing `CHMOD` rather than an exact
    /// spelling.
    ///
    /// Both halves: the answer is `true`, and no round trip was spent on it.
    @Test func theFEATSignalAnswersThePermissionProbeWithNoRoundTrip() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false,
            advertisesSiteChmodInFEAT: true)
        let offered = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            let answer = await fs.offersPermissionEditing()
            await fs.disconnect()
            return answer
        }
        #expect(offered)
        // The positive that says `FEAT` really carried it: the feature set
        // the dial read holds the line.
        let features = await server.receivedCommands.map(\.verb)
        #expect(features.contains("FEAT"))
        // And the negative that is the point: signal 2 was not needed.
        let helps = await server.receivedCommands.filter { $0.verb == "SITE" }
        #expect(helps.isEmpty)
    }

    /// Two asks that arrive together share ONE probing pass.
    ///
    /// Coverage rather than behaviour — the worst case is one extra round
    /// trip — but it is cheap against this fixture, and the in-flight branch
    /// is a third of the memory's logic. The two asks are started as separate
    /// tasks so they really do overlap; `helps.count == 1` is what says the
    /// second found the first's pass rather than starting its own.
    @Test func twoPermissionAsksThatOverlapShareOneProbingPass() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let answers = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            async let first = fs.offersPermissionEditing()
            async let second = fs.offersPermissionEditing()
            let both = await (first, second)
            await fs.disconnect()
            return both
        }
        #expect(answers.0)
        #expect(answers.1)
        let helps = await server.receivedCommands.filter {
            $0.verb == "SITE" && $0.argument.uppercased() == "HELP"
        }
        #expect(helps.count == 1)
    }

    /// The third answer, and the one that is a decision rather than a reading:
    /// a server that ANSWERED `SITE HELP` and said nothing about `CHMOD`.
    ///
    /// Inconclusive, so the editor is offered — hiding a working one on no
    /// evidence takes a feature away, where showing one a particular file
    /// refuses is what the design's decision 10 says a per-file error is for.
    /// And an inconclusive pass is NOT remembered, which the second ask
    /// measures: it probes again, and this time the server lists `CHMOD`, so
    /// the answer that gets kept is the one with evidence behind it.
    @Test func anInconclusivePermissionProbeOffersTheEditorAndIsAskedAgain() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let answers = try await Self.running(server) { host, port in
            let fs = try await Self.connect(server, host: host, port: port)
            await server.omitChmodFromNextSiteHelp()
            let inconclusive = await fs.offersPermissionEditing()
            let second = await fs.offersPermissionEditing()
            let third = await fs.offersPermissionEditing()
            await fs.disconnect()
            return (inconclusive: inconclusive, second: second, third: third)
        }
        #expect(answers.inconclusive)
        #expect(answers.second)
        #expect(answers.third)
        // Two `SITE HELP`s and not three: the inconclusive pass was re-asked
        // and the conclusive one was kept. Three would mean nothing is ever
        // remembered; one would mean an inconclusive answer is.
        let helps = await server.receivedCommands.filter {
            $0.verb == "SITE" && $0.argument.uppercased() == "HELP"
        }
        #expect(helps.count == 2)
    }

    /// `PermissionsAvailability` reads the capability FIRST and the probe only
    /// narrows it — so the per-connection answer can agree with the per-kind
    /// one or be `false` where it said `true`, and never the other way round.
    @Test func theAvailabilityHelperReadsTheCapabilityBeforeTheProbe() async throws {
        // FTP's capability row says `.posixMode`, so the kind alone offers it.
        #expect(PermissionsAvailability.isOffered(for: .ftp))

        // A server that DOES offer `SITE CHMOD`, asked against a kind whose
        // permission model is not `.posixMode`. That pairing is the only one
        // that can tell the two orders apart: capability-first answers
        // `false`, probe-first answers `true`. A bare server would answer
        // `false` either way and measure nothing — which is what the first
        // version of this case did.
        let offering = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let ordering = try await Self.running(offering) { host, port in
            let fs = try await Self.connect(offering, host: host, port: port)
            let probeSaysYes = await fs.offersPermissionEditing()
            let asWebDAV = await PermissionsAvailability.isOffered(for: .webdav, on: fs)
            let asFTP = await PermissionsAvailability.isOffered(for: .ftp, on: fs)
            await fs.disconnect()
            return (probeSaysYes: probeSaysYes, asWebDAV: asWebDAV, asFTP: asFTP)
        }
        #expect(ordering.probeSaysYes)
        #expect(ordering.asWebDAV == false)
        #expect(ordering.asFTP)

        // And the narrowing half: a connection whose probe says `false`
        // overrides a capability that says `true`.
        let bare = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false,
            offersSiteCommands: false)
        let narrowed = try await Self.running(bare) { host, port in
            let fs = try await Self.connect(bare, host: host, port: port)
            let asFTP = await PermissionsAvailability.isOffered(for: .ftp, on: fs)
            await fs.disconnect()
            return asFTP
        }
        #expect(narrowed == false)

        // A connection that is NOT a probe keeps the per-kind answer, which
        // is every other backend.
        let local: any RemoteFileSystem = LocalFileSystem()
        let localIsNotAProbe = (local as? any PermissionEditingProbe) == nil
        #expect(localIsNotAProbe)
        #expect(await PermissionsAvailability.isOffered(for: .ssh, on: local))
    }

    // MARK: - MDTM's own format

    /// `MDTM`'s fourteen digits, and the four ways they are refused.
    ///
    /// Read off the parser directly because a server cannot be made to send
    /// a malformed `MDTM`: this fixture composes its own, and the shapes
    /// below are what a real server's clock or locale produces.
    @Test func anMDTMStampIsFourteenUTCDigitsOrNothing() {
        #expect(
            FTPTimestamp.parse("20260304050607")
                == Date(timeIntervalSince1970: 1_772_600_767))
        // A fraction is tolerated and DISCARDED: nothing here compares a
        // sub-second modification time, and `MLSD`'s own reader adds it.
        #expect(
            FTPTimestamp.parse("20260304050607.250")
                == Date(timeIntervalSince1970: 1_772_600_767))
        // Thirteen digits, a non-digit, a date that is not a date, and empty.
        #expect(FTPTimestamp.parse("2026030405060") == nil)
        #expect(FTPTimestamp.parse("2026030405060x") == nil)
        #expect(FTPTimestamp.parse("20260230050607") == nil)
        #expect(FTPTimestamp.parse("") == nil)
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

    /// The config `connect` hands to the pool carries NO password.
    ///
    /// `connect`'s own comment argues this in the strongest available form —
    /// "a value type that never held the secret cannot print it" — and the
    /// review measured it held by nothing: replacing
    /// `var secretFree = config` plus `secretFree.password = ""` with
    /// `let secretFree = config`, so the pool's long-lived copy keeps the
    /// credential, was GREEN against the whole suite.
    /// `thePasswordIsReadFromTheConfigAndNowhereElse` measures something
    /// adjacent and different: that the password is READ FROM the config.
    ///
    /// **A source scan rather than a reading**, because
    /// `FTPConnectionPool`'s `config` is `private let` and so is out of reach
    /// even under `@testable`, and relaxing that to buy one test would widen
    /// a surface to narrow a guard. Read through `SourceCorpus.code(of:)`,
    /// which blanks comments and string literals while preserving length, so
    /// a comment quoting any of these spellings can neither satisfy nor trip
    /// the scan (CLAUDE.md, "Source-scanning guards read comments too") and
    /// the `""` in the clearing line survives as `""`.
    ///
    /// **Three POSITIVE checks before the negative**, which is what makes it
    /// a guard rather than a comment that runs: the pool is constructed here
    /// at all, the clearing line is present AND CLEARS TO `""`, and the
    /// CLEARED copy is what the `config:` argument receives.
    ///
    /// That second positive first read `occurrences(of: "secretFree.password =")`,
    /// which was the left-hand side alone and therefore said only that
    /// SOMETHING is assigned to the field. The re-review planted
    /// `secretFree.password = config.password` — the clearing kept, spelled,
    /// and neutered — and it was **GREEN over 238 FTP tests**: a copy that
    /// re-reads the credential satisfied every check in this case. The
    /// anchor is now the whole assignment — read through
    /// `SourceCorpus.commentFree(of:)` rather than `code(of:)`, because the
    /// `""` does NOT survive the blanked view.
    ///
    /// This comment first claimed the opposite, verbatim: "Read through
    /// `SourceCorpus.code(of:)`, which blanks comments and string literals
    /// while preserving length, so a comment quoting any of these spellings
    /// can neither satisfy nor trip the scan (CLAUDE.md, "Source-scanning
    /// guards read comments too") and the `""` in the clearing line survives
    /// as `""`." The first half is true and is why every other check here
    /// still reads the blanked view. The last clause is false, measured:
    /// anchoring the clearing check on `secretFree.password = ""` against
    /// `code(of:)` reports **0** and reddens this case on a correct tree.
    /// `commentFree(of:)` blanks comments and KEEPS literals, which is
    /// exactly the pair of properties this one check needs — so the clearing
    /// check reads that view and gets its own two counter-controls, while
    /// the negative keeps the blanked view, where no string literal can
    /// spell `config: config` into a pass or a failure. Without them an emptied-out scan, or one
    /// pointed at a file that no longer builds a pool, would read as
    /// satisfied. The negative is that the ORIGINAL config is not what goes
    /// in.
    ///
    /// The spellings are literals because there is no symbol to walk back to:
    /// `secretFree` is a local and `config:` is an argument label on an
    /// initializer the scan is checking the arguments of. Each is unique in
    /// the file, which the counts below assert rather than assume.
    @Test func theConfigHandedToThePoolCarriesNoPassword() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("macSCPCore/FTP/FTPFileSystem.swift")
        let code = try SourceCorpus.code(of: url)
        let codeKeepingLiterals = try SourceCorpus.commentFree(of: url)

        func occurrences(of token: String, in text: String) -> Int {
            guard !token.isEmpty else { return 0 }
            var count = 0
            var searched = text.startIndex
            while let found = text.range(of: token, range: searched..<text.endIndex) {
                count += 1
                searched = found.upperBound
            }
            return count
        }
        func occurrences(of token: String) -> Int { occurrences(of: token, in: code) }

        // The three positives.
        #expect(occurrences(of: "FTPConnectionPool(") == 1)
        #expect(occurrences(of: "secretFree.password = \"\"", in: codeKeepingLiterals) == 1)
        #expect(occurrences(of: "config: secretFree") == 1)
        // The negative: the config that still holds the credential is not
        // what the pool is given.
        #expect(occurrences(of: "config: config") == 0)
        // The counter's own controls, so neither a 1 nor a 0 above is a
        // pattern that can no longer match anything.
        #expect(occurrences(of: "password") > 0)
        #expect(occurrences(of: "thisTokenIsNotInTheFile") == 0)
        // And the literal-keeping view's own controls, because an empty
        // string literal is the one token the blanked view cannot carry.
        #expect(occurrences(of: "password", in: codeKeepingLiterals) > 0)
        #expect(occurrences(of: "thisTokenIsNotInTheFile", in: codeKeepingLiterals) == 0)
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
