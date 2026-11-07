import Foundation

/// The FTP and FTPS backend: `RemoteFileSystem` over the control connection,
/// the data connection, the pool and the lease.
///
/// **What runs where, and it is spec §5 rather than a preference.** Listing,
/// `stat`, rename, delete, `MKD` and `SITE CHMOD` run on the pool's RESERVED
/// command connection, so a running upload never blocks the browser; the byte
/// transfers — `RETR` and `STOR` — each take a connection of their own from
/// the pool, through an `FTPTransferLease`.
///
/// **A listing is a data transfer on the command connection, which is the one
/// hole in the lease boundary, and §5 is what puts it there.** The lease is
/// the only way to spend a POOLED connection, because a pooled connection has
/// a release invariant (§5a) and the command connection has none — nothing
/// takes it away and nothing waits for it. `FTPDataConnection.transfer` is
/// static and takes any connection, so this file can and does run `MLSD` and
/// `LIST` on the command connection; what it never does is run `RETR` or
/// `STOR` there. The structural gap — that nothing in the type system
/// enforces the distinction — is an owed `docs/BACKLOG.md` row, and the shape
/// of its eventual fix is constrained by this: it cannot be "only a lease may
/// transfer", because §5 requires the command connection to carry a listing.
///
/// **No `deinit` cleanup.** `disconnect()` shuts the pool down, which closes
/// the command connection and every idle transfer connection; the UI owns the
/// order (`CLAUDE.md`, architecture invariants).
public final class FTPFileSystem: RemoteFileSystem {
    /// The pool, INTERNAL rather than private for one property: §5a's release
    /// invariant. `FTPConnectionPool.freeTransferSlots` is how a case sees
    /// that a transfer gave its connection back — through the stream's
    /// termination, through a thrown error, or through abandonment — and
    /// there is no way to observe that from outside the pool. A caller in
    /// Core could reach around this type with it; nothing does, and the
    /// alternative was a seam that exists only for tests.
    let pool: FTPConnectionPool

    /// Where the session opens, when the user named a folder
    /// (`FTPConnectionConfig.initialPath`). `nil` means whatever the server
    /// starts in, which is what `PWD` answers.
    private let initialPath: String?

    private init(pool: FTPConnectionPool, initialPath: String?) {
        self.pool = pool
        self.initialPath = initialPath
    }

    // MARK: - Dialling

    /// Opens the session: builds the pool and dials its command connection,
    /// so a refused login or an untrusted certificate fails HERE and not on
    /// the browser's first listing.
    ///
    /// **`config.password` is the credential, and it is read exactly once —
    /// here.** The config that goes on to the pool is a copy with the
    /// password cleared, which is the shape
    /// `FTPControlConnection.connect(_:password:…)` asks for in as many
    /// words: "a value type that never held the secret cannot print it". The
    /// pool therefore holds the secret in one `let` of its own and the long-
    /// lived configuration value holds none.
    ///
    /// Module-internal, like every backend's dial: the only way in from
    /// outside Core is `BackendDescriptor.openConnection`, which supplies the
    /// decider, the trust store and the configured connect timeout.
    ///
    /// `transferSlots` has no default. Spec §5b says the pool is sized from
    /// `SettingsStore.maxConcurrentTransfers` — one number, the existing one
    /// — and a default here would be a second copy of it that a caller gets
    /// by typing nothing.
    static func connect(
        _ config: FTPConnectionConfig,
        transferSlots: Int,
        certificateDecider: CertificateDecider,
        timeout: Duration,
        trustStore: TrustedCertificateStore?,
        tuning: FTPControlConnection.Tuning = .default
    ) async throws -> FTPFileSystem {
        var secretFree = config
        secretFree.password = ""
        let pool = FTPConnectionPool(
            config: secretFree,
            password: config.password,
            transferSlots: transferSlots,
            certificateDecider: certificateDecider,
            timeout: timeout,
            trustStore: trustStore,
            tuning: tuning)
        do {
            _ = try await pool.command()
        } catch {
            await pool.shutdown()
            throw Self.connectFailure(error)
        }
        return FTPFileSystem(pool: pool, initialPath: config.initialPath)
    }

    /// What a failed DIAL is reported as.
    ///
    /// `RemoteFSError.connectionFailed(reason:)` with the failure's own
    /// localized sentence, which is this module's text in four languages —
    /// not a server's words, and not English inside a translated frame. Every
    /// `FTPConnectionFailure` reaching this function really is a connection
    /// that did not open, so `isConnectionFailure` answering `true` for it is
    /// correct.
    ///
    /// **The sentence carries no host, port, credential or fingerprint**, and
    /// it cannot: `FTPConnectionFailure` holds at most a reply code, and
    /// `message` is a fixed catalogue entry. That is the whole reason the
    /// certificate cases are payload-free — `certificateMismatch`'s question
    /// is answered with two fingerprints inside `FTPTrustDecision` and
    /// neither of them leaves it.
    private static func connectFailure(_ error: any Error) -> any Error {
        guard let failure = error as? FTPConnectionFailure else { return error }
        return RemoteFSError.connectionFailed(reason: failure.message)
    }

    // MARK: - Listing

    /// One directory, through `MLSD` when the server advertises it and `LIST`
    /// otherwise.
    ///
    /// **`MLSD` is preferred because it is specified.** RFC 3659 fixes its
    /// format — `fact=value;…  name`, with a typed `type` fact and a UTC
    /// `modify` — where `LIST` has no specified format at all and
    /// `FTPListParser` has to guess a dialect from the first byte of each
    /// line. So the fallback is a fallback, not an equal: a server with no
    /// `MLSD` gets the Unix/DOS readers and a line in neither dialect fails
    /// the directory.
    ///
    /// Asked of `FEAT`, which the dial read once, so the preference costs no
    /// round trip per listing.
    public func list(path: String) async throws -> [RemoteFileItem] {
        let directory = RemotePath.normalizedAbsolute(path)
        let connection = try await pool.command()
        let advertisesMLSD = await connection.features.contains("MLSD")
        let lines = try await Self.listingLines(
            of: directory, verb: advertisesMLSD ? "MLSD" : "LIST", on: connection)
        do {
            return advertisesMLSD
                ? try FTPListParser.mlsd(lines, at: directory)
                : try FTPListParser.list(lines, at: directory)
        } catch FTPListRefusal.unreadableLine(let index) {
            // `FTPListParser` counts from 0 and a person reads from 1. This
            // is the one place that converts.
            throw RemoteFSError.finding(.listingLineUnreadable(line: index + 1))
        }
    }

    /// The listing's bytes, split into lines with their terminators dropped.
    ///
    /// On the COMMAND connection — see this type's own comment for why that
    /// is §5 and not a shortcut past the lease.
    ///
    /// The whole listing is accumulated before it is parsed, which is the one
    /// place in this backend that holds a transfer in memory on purpose: a
    /// listing is parsed as a whole (a line in no dialect fails the
    /// directory, so there is no answer to give until the last line is in)
    /// and the items it becomes are held anyway.
    private static func listingLines(
        of directory: String, verb: String, on connection: FTPControlConnection
    ) async throws -> [Data] {
        let sink = FTPListingSink()
        try await FTPDataConnection.transfer(verb, argument: directory, on: connection) { channel in
            try await channel.read { chunk in sink.append(chunk) }
        }
        return sink.lines()
    }

    // MARK: - One entry

    /// The entry at `path`.
    ///
    /// FTP has no `stat`, so this is assembled, and the order is chosen to
    /// cost as little as possible for the question that is asked most often —
    /// "how big is this file, and when did it change", which `TransferEngine`
    /// asks before every transfer:
    ///
    /// 1. The root is a directory, answered without asking. There is no
    ///    parent to list it from, and no server reports `/` as a file.
    /// 2. `SIZE`, when `FEAT` advertises it. A `213` means the path is a
    ///    FILE — `SIZE` is defined for files, and a server that answers it
    ///    for a directory is answering a question nobody can use — and
    ///    `MDTM` then supplies the timestamp. Two commands, no data
    ///    connection.
    /// 3. Otherwise the PARENT is listed and the entry found by name. That is
    ///    the only thing that answers a directory, a symlink, the permission
    ///    bits and the owner, and it costs a data connection.
    ///
    /// A path that step 3 does not find is `notFound`.
    public func stat(path: String) async throws -> RemoteFileItem {
        let target = RemotePath.normalizedAbsolute(path)
        guard target != "/" else {
            return RemoteFileItem(name: "/", path: "/", kind: .directory)
        }
        let connection = try await pool.command()
        let features = await connection.features
        if features.contains("SIZE"), let size = try await Self.size(of: target, on: connection) {
            let modified = features.contains("MDTM")
                ? try await Self.modificationTime(of: target, on: connection)
                : nil
            return RemoteFileItem(
                name: (target as NSString).lastPathComponent, path: target, kind: .file,
                size: size, modifiedAt: modified)
        }
        let parent = RemotePath.parent(of: target)
        let name = (target as NSString).lastPathComponent
        guard let entry = try await list(path: parent).first(where: { $0.name == name }) else {
            throw RemoteFSError.notFound(path: target)
        }
        return entry
    }

    /// `SIZE`'s answer, or `nil` when the server refused it — which is what a
    /// directory, a missing path and an unreadable one all look like, and
    /// telling them apart is the parent listing's job.
    private static func size(
        of path: String, on connection: FTPControlConnection
    ) async throws -> UInt64? {
        let reply = try await connection.send("SIZE", argument: path)
        guard reply.isPositiveCompletion else { return nil }
        return reply.lines.first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `MDTM`'s answer, or `nil` when the server refused it or wrote
    /// something this reader cannot place.
    ///
    /// Best effort, like every other backend's timestamp: a file whose
    /// modification time cannot be read is still a file, and nothing that
    /// compares two folders reads a timestamp (`FTPListParser`'s own note).
    private static func modificationTime(
        of path: String, on connection: FTPControlConnection
    ) async throws -> Date? {
        let reply = try await connection.send("MDTM", argument: path)
        guard reply.isPositiveCompletion, let text = reply.lines.first else { return nil }
        return FTPTimestamp.parse(text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Reading

    /// The file's bytes from `offset`, through a transfer lease.
    ///
    /// `offset > 0` becomes `REST`, and a server that refuses `REST` ends the
    /// transfer rather than sending the file from the beginning
    /// (`FTPConnectionFailure.restRefused`): a client that carried on would
    /// write the whole file at the offset and leave the head in the middle of
    /// it, with no error anywhere.
    ///
    /// **The lease is released on every way this stream can end**, including
    /// the one a `defer` cannot cover — a consumer that stops iterating and
    /// drops the stream. That is spec §5a, and `FTPTransferLease.readStream`
    /// is where it is implemented.
    ///
    /// It cannot `throw` before the stream exists in the way the other
    /// methods do: the lease has to be acquired first, and that waits for a
    /// slot. A failure to acquire one therefore throws from HERE, before any
    /// stream is handed back.
    public func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let target = RemotePath.normalizedAbsolute(path)
        let lease = try await pool.acquireTransfer()
        return lease.readStream(target, startingAt: Int64(clamping: offset))
    }

    // MARK: - Writing

    /// Writes the chunk stream as `STOR`, through a transfer lease.
    ///
    /// **`.append` is refused**, and `supportsAppendResume` says so, so
    /// `TransferEngine` never asks: `effectiveResume` needs the destination's
    /// own `true` (`TransferEngine.swift`, `let effectiveResume = resume &&
    /// destination.supportsAppendResume`). This throw is defence in depth,
    /// the same pairing `WebDAVFileSystem` has — and the reason it is
    /// refused rather than implemented is argued at
    /// `supportsAppendResume` below.
    public func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        guard mode == .overwrite else { throw RemoteFSError.finding(.resumeNotSupported) }
        let target = RemotePath.normalizedAbsolute(path)
        let lease = try await pool.acquireTransfer()
        try await lease.transferring("STOR", argument: target) { channel in
            for try await chunk in contents {
                try await channel.write(chunk)
            }
        }
    }

    /// FTP cannot continue an interrupted UPLOAD safely, so it does not
    /// offer to (the decision this task owns; spec §7a left it open because
    /// "getting it wrong corrupts files silently").
    ///
    /// **The substitute check the spec offered cannot be built, and that is
    /// structural rather than a matter of odds.** The proposal was "size plus
    /// `MDTM` before the `REST`". What resuming an upload has to establish is
    /// that the destination is still the partial file THIS client wrote; what
    /// the two commands can establish is only what the destination looks like
    /// NOW. `MDTM` needs an earlier reading to be compared against, and there
    /// is none: `TransferEngine` takes the resume offset from
    /// `destination.stat(path:).size` and carries no destination validator
    /// between attempts — `entityTag`, `statWithEntityTag` and
    /// `readStream(…ifMatching:)` are all about the SOURCE, and FTP has no
    /// validator to put in them anyway. So the check reduces to "the
    /// destination is as long as I believe I wrote", which any replacement of
    /// equal length satisfies.
    ///
    /// The cost of being wrong is the worst available here: appending the
    /// tail of one file to the head of another produces a file of exactly the
    /// right length and entirely wrong contents, which nothing downstream can
    /// notice. `aResumedUploadOntoAReplacedRemoteFileDoesNotProduceASplicedFile`
    /// is the case, and it measures the blind spot — `SIZE` reads the same
    /// number for the partial file and for an equal-length replacement —
    /// beside the refusal.
    ///
    /// Resuming a DOWNLOAD is unaffected and works: `REST` before `RETR`
    /// (`readStream(path:fromOffset:)`), with the partial file on the local
    /// disk, whose file system answers `true` to this question.
    public var supportsAppendResume: Bool { false }

    // MARK: - Mutations

    /// `DELE`.
    ///
    /// The contract distinguishes "nothing is there" from "that is a
    /// directory", and FTP does not: a server answers `550` to both. So the
    /// disambiguation is a `stat` on the REFUSAL path only — a delete that
    /// succeeds pays nothing for it.
    public func delete(path: String) async throws {
        let target = RemotePath.normalizedAbsolute(path)
        let connection = try await pool.command()
        let reply = try await connection.send("DELE", argument: target)
        guard !reply.isPositiveCompletion else { return }
        let entry = try? await stat(path: target)
        guard let entry else { throw RemoteFSError.notFound(path: target) }
        guard entry.kind != .directory else {
            throw RemoteFSError.protocolError(reason: "path is a directory: \(target)")
        }
        throw RemoteFSError.finding(.unexpectedStatus(code: reply.code))
    }

    /// `MKD`, idempotent as the contract requires.
    ///
    /// A server answers `550` to "it is already there" and to "something else
    /// is there", so the refusal is disambiguated by a `stat`, on the refusal
    /// path only. ONE level, like `CitadelFileSystem`: the recursion runs
    /// top-down, so parents always exist by the time this is called.
    public func createDirectory(at path: String) async throws {
        let target = RemotePath.normalizedAbsolute(path)
        let connection = try await pool.command()
        let reply = try await connection.send("MKD", argument: target)
        guard !reply.isPositiveCompletion else { return }
        guard let entry = try? await stat(path: target) else {
            throw RemoteFSError.finding(.unexpectedStatus(code: reply.code))
        }
        guard entry.kind == .directory else {
            throw RemoteFSError.finding(.pathExistsAndIsNotADirectory(path: target))
        }
    }

    /// `RNFR` then `RNTO`, which is why `atomicRename` is false for FTP: they
    /// are two commands and a server may serve something else between them.
    ///
    /// **The destination is checked first, by this client**, because the
    /// contract says a rename "never silently overwrites" and several real
    /// servers do exactly that — vsftpd and ProFTPD replace an occupied
    /// destination without a word. There is a window between the check and
    /// the `RNTO` that nothing here can close: FTP has no conditional
    /// rename. Named rather than hidden; a check that closes the common case
    /// is worth one round trip, and the alternative is trusting a server
    /// behaviour that is not uniform.
    public func rename(from: String, to: String) async throws {
        let source = RemotePath.normalizedAbsolute(from)
        let destination = RemotePath.normalizedAbsolute(to)
        if (try? await stat(path: destination)) != nil {
            throw RemoteFSError.finding(.directoryAlreadyExists)
        }
        let connection = try await pool.command()
        let ready = try await connection.send("RNFR", argument: source)
        guard ready.isIntermediate else {
            guard (try? await stat(path: source)) != nil else {
                throw RemoteFSError.notFound(path: source)
            }
            throw RemoteFSError.finding(.unexpectedStatus(code: ready.code))
        }
        let done = try await connection.send("RNTO", argument: destination)
        guard done.isPositiveCompletion else {
            throw RemoteFSError.finding(.unexpectedStatus(code: done.code))
        }
    }

    /// `SITE CHMOD <mode> <path>`.
    ///
    /// An EXTENSION, not a protocol feature: `SITE` commands are whatever the
    /// server decided to offer, and a server that does not offer `CHMOD`
    /// answers `500`/`502`/`504`. So a refusal is reported for THAT FILE and
    /// never fails the connection — the control connection is in step either
    /// way, because the server answered.
    ///
    /// `permissions` is masked to the low twelve bits, as the contract says,
    /// and written in octal, which is the only notation `SITE CHMOD` takes.
    ///
    /// **Three refusals, three different answers**, because "this server has
    /// no `SITE CHMOD`" and "you may not change this file" are not the same
    /// thing to the person reading it:
    ///
    /// - `500`, `501`, `502`, `504` — the command, or the `SITE` subcommand,
    ///   is not implemented (RFC 959 section 4.2 lists these for an
    ///   unrecognised or unimplemented command) → `.operationNotSupported`.
    /// - `550` — the server understood and declined → `.permissionDenied`.
    /// - anything else → the code itself, for want of a reading.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        let target = RemotePath.normalizedAbsolute(path)
        let mode = String(permissions & 0o7777, radix: 8)
        let connection = try await pool.command()
        let reply = try await connection.send("SITE", argument: "CHMOD \(mode) \(target)")
        guard !reply.isPositiveCompletion else { return }
        switch reply.code {
        case 500, 501, 502, 504: throw RemoteFSError.finding(.operationNotSupported)
        case 550: throw RemoteFSError.permissionDenied(path: target)
        default: throw RemoteFSError.finding(.unexpectedStatus(code: reply.code))
        }
    }

    /// Deletes the entry and, for a directory, everything under it: `DELE`
    /// for each file and `RMD` for each directory, deepest first, because
    /// `RMD` removes an EMPTY directory only.
    ///
    /// **A symlink is deleted and never followed**, which is `DELE`'s own
    /// behaviour: `DELE` removes the link. The walk therefore cannot escape
    /// the subtree, which is the invariant the contract states.
    ///
    /// Cooperatively cancellable per entry; a cancellation leaves a partly
    /// deleted tree in place, as the contract says.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        let target = RemotePath.normalizedAbsolute(path)
        let entry = try await stat(path: target)
        guard entry.kind == .directory else {
            try await delete(path: target)
            return
        }
        for child in try await list(path: target) {
            try Task.checkCancellation()
            if child.kind == .directory {
                try await deleteTree(at: child.path)
            } else {
                try await delete(path: child.path)
            }
        }
        try Task.checkCancellation()
        let connection = try await pool.command()
        let reply = try await connection.send("RMD", argument: target)
        guard !reply.isPositiveCompletion else { return }
        throw RemoteFSError.finding(.unexpectedStatus(code: reply.code))
    }

    // MARK: - The session

    /// Where the browser opens: the folder the user named, or `PWD`'s answer.
    ///
    /// `FTPConnectionConfig.initialPath` is "the folder to open first", and
    /// this is the one thing that reads it — the field had no reader at all
    /// until this file.
    ///
    /// `PWD` answers `257 "<path>" is the current directory` (RFC 959
    /// section 4.2), and the path is quoted because it may contain spaces; a
    /// literal quote inside it is doubled.
    public func homeDirectoryPath() async throws -> String {
        if let initialPath, !initialPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return RemotePath.normalizedAbsolute(initialPath)
        }
        let connection = try await pool.command()
        let reply = try await connection.send("PWD", argument: nil)
        guard reply.isPositiveCompletion, let text = reply.lines.first,
            let quoted = Self.quotedPath(in: text)
        else {
            // The contract says callers fall back to `/`, and so does this:
            // a session that cannot name its landing folder still browses.
            return "/"
        }
        return RemotePath.normalizedAbsolute(quoted)
    }

    /// The path between the FIRST quote and the LAST one, with doubled quotes
    /// collapsed (RFC 959 section 4.2's `"` escaping). `nil` when the reply
    /// carries no quoted pair.
    ///
    /// Outermost rather than first-to-first, like
    /// `FTPDataConnection.parenthesised`: a path may contain quotes and the
    /// server's human text follows the path.
    static func quotedPath(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""),
            open < close
        else { return nil }
        let inner = String(text[text.index(after: open)..<close])
        return inner.replacingOccurrences(of: "\"\"", with: "\"")
    }

    public func disconnect() async {
        await pool.shutdown()
    }
}

/// FTP's answer to the checksum question, which is that it has none.
///
/// Said as an outcome rather than left as a hole, for the reason
/// `WebDAVFileSystem`'s own conformance gives: a backend that simply did not
/// conform comes back `nil` from the surface's `as?`, and a caller holding
/// nothing has only a greyed-out menu entry to offer.
///
/// `XCRC`, `XMD5` and RFC 7239's `HASH` exist, and none of them is in the
/// protocol: they are per-server extensions, advertised by some `FEAT`
/// replies and absent from most, each with its own argument form. Reading one
/// is its own piece of work with its own way of finding out whether it is
/// there, exactly as `OC-Checksum` is for WebDAV.
/// `ProtocolCapabilities.supportsRemoteChecksum` is `false` for FTP, and the
/// two say different things: the capability is what a menu consults before it
/// is built, this is what a caller that asked anyway gets told.
extension FTPFileSystem: RemoteChecksumProvider {
    /// Answers without asking the server: no FTP command this backend sends
    /// can turn this into a checksum, so spending a round trip would only
    /// make the same answer slower.
    public func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        .unavailableOnThisConnection
    }
}

/// `MDTM`'s timestamp format, read.
///
/// Its own type rather than a method on `FTPFileSystem` because
/// `FTPListParser` already reads the identical format out of an `MLSD`
/// `modify` fact, and a second copy of a date parser is a second thing to get
/// wrong. The parser is not SHARED, which is the honest description: this one
/// is `MDTM`'s reply and that one is a fact value, and they are the same
/// fourteen digits. If a third reader appears, they merge.
enum FTPTimestamp {
    /// `YYYYMMDDHHMMSS`, optionally with a `.sss` fraction, always UTC
    /// (RFC 3659 section 2.3). `nil` for anything else — a timestamp is best
    /// effort, and a server that writes a local time with no zone cannot be
    /// distinguished from one that obeys the RFC.
    static func parse(_ value: String) -> Date? {
        let whole = value.prefix { $0 != "." }
        guard whole.count == 14, whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let digits = Array(whole).compactMap { $0.wholeNumberValue }
        guard digits.count == 14 else { return nil }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        var components = DateComponents()
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(8..<10)
        components.minute = number(10..<12)
        components.second = number(12..<14)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar rolls an impossible date forward in silence, so the result
        // is read back and compared — `FTPListParser.utcDate`'s own guard.
        let back = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == components.year, back.month == components.month,
            back.day == components.day, back.hour == components.hour,
            back.minute == components.minute, back.second == components.second
        else { return nil }
        return date
    }
}

/// A listing's bytes as they arrive, split into lines when the transfer ends.
///
/// A reference type because the drain is a `@Sendable` closure
/// (`FTPDataConnection.transfer` hands it across an actor boundary), so it
/// cannot capture a mutable local. `@unchecked Sendable` with no lock, and
/// that is argued rather than assumed: `FTPDataChannel.read` awaits its sink
/// before it reads on, so the appends are strictly sequential and there is
/// never a second writer — the same single-consumer property
/// `FTPSingleReader` makes a `precondition` out of, here with no concurrent
/// reader to race.
final class FTPListingSink: @unchecked Sendable {
    private var bytes = Data()

    func append(_ chunk: Data) {
        bytes.append(chunk)
    }

    /// The lines, CR LF or LF terminated, with their terminators dropped.
    ///
    /// A lone CR left behind by an LF-only split is NOT dropped here and does
    /// not have to be: `FTPListParser` refuses a line it cannot read, and a
    /// stray CR makes a line unreadable in both dialects, which is the
    /// correct outcome for a listing that arrived mangled. What is dropped is
    /// the CR that belongs to a CR LF pair.
    func lines() -> [Data] {
        var lines: [Data] = []
        for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.last == UInt8(ascii: "\r") {
                lines.append(Data(line.dropLast()))
            } else {
                lines.append(Data(line))
            }
        }
        // A listing ends with a terminator, so the split leaves one empty
        // trailing element. `FTPListParser` skips an empty line anyway; it is
        // dropped here so the INDEX a refusal names is not one past the end
        // for a listing whose last real line is the bad one.
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
