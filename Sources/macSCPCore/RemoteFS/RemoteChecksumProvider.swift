import Foundation

/// What a connection answered when it was asked for a file's checksum.
public enum RemoteChecksumOutcome: Sendable, Equatable {
    /// A value, carrying where it came from — computed on the far side,
    /// computed here, or read off an object store's ETag.
    case checksum(FileChecksum)
    /// This connection cannot answer the question — for any file, not just
    /// this one. An SSH far side with no checksum tool answers it, and so
    /// does WebDAV, which has no digest to report at all.
    ///
    /// A case and not an error, because it is an answer: "this server does
    /// not offer checksums" is something to say to the user, where a thrown
    /// failure invites a dead, greyed-out menu entry instead. It is also not
    /// the answer for a single file that went wrong — an unreadable answer
    /// about one file is a `RemoteFSError`, because the next file may be
    /// fine.
    case unavailableOnThisConnection
}

/// A backend capability queried via `as?`, like `RemoteShellProvider` and
/// `PresignedURLProvider`: the digest of one file, without moving its bytes
/// anywhere.
///
/// Where that digest comes from is the backend's business and the answer
/// says which: SSH has the far side compute it, the local file system
/// computes it here over a file that is already here, S3 reports the ETag
/// its listing carries, and WebDAV answers that it cannot. That is every
/// backend this project has — so a surface asks the same question of all of
/// them and never branches on `ConnectionKind`. What no backend does is
/// download a file in order to hash it; the maintainer ruled that out on
/// 2026-08-27, fallbacks included, and it is why S3's answer is an ETag or
/// nothing.
///
/// Read the parameter list, because it is the whole design. A path and one
/// of three algorithms — and no third parameter. Nothing here carries a
/// command, an argument list, an executable name, or a flag, so a caller
/// cannot phrase one. Not because a test forbids it: because there is no
/// such expression. `ChecksumCommandForm` supplies the tool and its
/// arguments from a two-case enum, the path is interpolated only through
/// `PosixQuoting.singleQuoted` into a single shell word, and the line that
/// results is a `ChecksumCommandLine`, whose initializer no other file can
/// reach.
///
/// A general execution entry point would have been the alternative, and it
/// would have been a new surface every future reviewer had to watch. This
/// project's record with source-scanning guards over such surfaces is in
/// `CLAUDE.md`, and it is why the narrow capability is the design rather
/// than a preference.
public protocol RemoteChecksumProvider: Sendable {
    /// The digest of the file at `path` under `algorithm`.
    ///
    /// `algorithm` is what the caller ASKED for, and a backend that computes
    /// on demand delivers exactly it. An object store computes nothing on
    /// demand, so S3 answers with the ETag's MD5 whatever was asked — which
    /// is visible rather than silent, because a `FileChecksum` names its own
    /// algorithm and its own origin.
    ///
    /// Throws when the answer about THIS file could not be had: output that
    /// is not a checksum, a command that failed on the far side, a bound
    /// that elapsed, a path that is missing or is a directory. Returns
    /// `.unavailableOnThisConnection` when the backend cannot answer for any
    /// file — see `RemoteChecksumOutcome` for why that one is not a throw.
    func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome
}

/// The single operation `RemoteChecksumRun` asks of a connection: run one
/// `ChecksumCommandLine` and hand back its STANDARD OUTPUT.
///
/// Standard output only, never a merged stream, and that is a requirement
/// rather than a preference: `ChecksumOutputReader` refuses output of more
/// than one line, so a far side that writes anything of its own — a login
/// banner, a shell's warning about a locale — would turn every file's
/// checksum into "unreadable" the moment its lines were folded in with the
/// digest's. A conforming channel therefore discards standard error rather
/// than merging it.
///
/// Internal on purpose. The public surface is `RemoteChecksumProvider`; this
/// seam exists so the decisions above it — quoting, which form, how a bad
/// answer is treated — are testable against a double without a connection.
/// It takes a `ChecksumCommandLine` and not a `String`, so being internal is
/// not what keeps it narrow.
protocol ChecksumCommandChannel: Sendable {
    func standardOutput(of line: ChecksumCommandLine) async throws -> String
}

extension ChecksumCommandChannel {
    /// How much standard output a conforming channel may collect before it
    /// gives up on the answer.
    ///
    /// The longest legitimate answer is one line: at most 64 hex digits (the
    /// longest of `ChecksumAlgorithm`'s three lengths), a two-character
    /// separator, and the path echoed back, which Linux caps at a
    /// `PATH_MAX` of 4096 bytes — 4162 bytes together. 8 KiB is comfortably
    /// past that and still far from anything a far side could use to fill
    /// this process's memory while we wait out the run bound.
    static var maxStandardOutputBytes: Int { 8 * 1024 }
}

/// The wall-clock bounds one checksum request may spend waiting.
///
/// There has to be a bound at all for the reason measured twice in the week
/// of 2026-08-28 and written up at `BoundedSFTPSession.closeBoundSeconds`: a
/// Citadel call against a peer that has stopped answering does not return,
/// and `try?` never bounded a wait. A new waiting point without a ceiling
/// would have been the third.
///
/// Passed explicitly rather than defaulted, for `connectTimeout`'s reason in
/// `CitadelFileSystem.connect`: a defaulted bound is how a value goes
/// unconsidered for the life of a product. Production spells `.standard` —
/// a name, not a number, so no call site carries a second copy of one.
struct ChecksumBounds: Sendable, Equatable {
    /// For `command -v`, which starts nothing and touches no file. A round
    /// trip and no more.
    let probeSeconds: Int
    /// For the checksum itself, which reads the whole file on the far side.
    let runSeconds: Int

    /// The bounds a real connection uses.
    ///
    /// **15 s for the probe.** It is one round trip against a shell builtin;
    /// the only thing that can make it long is a link or a peer in trouble.
    /// It sits at Citadel's own "no reply" interval for opening an SFTP
    /// channel (15 s, cited in `CitadelFileSystem.disconnect()`), so an
    /// unanswered probe costs a user no more than any other unanswered
    /// request already does.
    ///
    /// **900 s — fifteen minutes — for the run**, argued from the size the
    /// design names. A checksum over 40 GB is minutes of real work on the
    /// far side, so the bound has to clear that or it would abandon correct
    /// answers: 900 s is 40 GB read and hashed at 46 MiB/s, which is under
    /// half of what a single plain hard disk sustains. Measured on
    /// 2026-08-31 for scale, on the two machines available: `shasum -a 256`
    /// (the Perl one, the slowest of the family) over 512 MiB on this host
    /// took 1.72 s — 298 MiB/s, at which rate the bound would cover about
    /// 260 GB — and GNU `sha256sum` over the same size in the Docker rig
    /// took 0.27 s.
    ///
    /// Not more, because the bound is a backstop and not the way out: the
    /// caller's own cancellation is, and a request that hangs past fifteen
    /// minutes is a connection in trouble rather than a large file.
    static let standard = ChecksumBounds(probeSeconds: 15, runSeconds: 900)
}

/// One value carried out of a `BoundedClose.run` operation.
///
/// `BoundedClose.run` takes a closure returning nothing, because the wait it
/// was written for has no result. This box is how a result comes back out of
/// one. It is read ONLY after `run` reported that the operation finished, so
/// a `nil` here would mean the operation completed without storing, which
/// neither caller below can do.
///
/// `@unchecked Sendable` because the payload is a `Result` carrying an
/// `Error`, which is not `Sendable` — that payload is the reason the box
/// exists. There is no unsynchronized state: `stored` is private and every
/// access goes through `lock`. That argument breaks the moment anything
/// reaches the storage without taking it.
private final class BoundedOutcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func store(_ value: Value) {
        lock.withLock { stored = value }
    }

    var value: Value? {
        lock.withLock { stored }
    }
}

/// Which command form one connection has — asked once, and then kept.
///
/// Once, because the answer is a property of the far side and not of the
/// request: `sha256sum` is GNU, `shasum -a 256` is BSD, and no far side
/// changes its mind mid-session. And a form rather than a compound
/// `sha256sum … || shasum …` line covering both cases at once, which would
/// have saved exactly one round trip and is the construction this project
/// rejected across eight review rounds elsewhere.
actor ChecksumFormMemory {
    private enum Memory {
        case unasked
        case answered(ChecksumCommandForm?)
    }

    /// What one probing pass found, and whether it is worth keeping.
    private struct Pass: Sendable {
        let form: ChecksumCommandForm?
        /// False when the bound elapsed before a form could answer. Such a
        /// pass learned nothing about the far side, so it is the one result
        /// that is not remembered.
        let conclusive: Bool
    }

    private var memory: Memory = .unasked
    private var inFlight: Task<Pass, Never>?

    /// The form this connection has, or `nil` if it has none.
    ///
    /// Two requests that arrive together share one probing pass: the first
    /// stores the task before it suspends, and the second finds it there and
    /// awaits the same answer instead of probing again.
    func form(
        over channel: some ChecksumCommandChannel, bounds: ChecksumBounds
    ) async -> ChecksumCommandForm? {
        if case .answered(let remembered) = memory { return remembered }
        if let inFlight { return await inFlight.value.form }

        let pass = Task { await Self.probe(over: channel, bounds: bounds) }
        inFlight = pass
        let result = await pass.value
        inFlight = nil
        if result.conclusive { memory = .answered(result.form) }
        return result.form
    }

    /// Asks the far side for each form in turn, in the enum's own order, and
    /// stops at the first one that is there.
    ///
    /// A form that answers anything but success — a non-zero exit, a channel
    /// the server refuses to open, a shell with no `command` builtin — is
    /// taken as absent, and when every form is absent the connection has no
    /// checksum capability. That is deliberately broader than "the tool is
    /// missing": an SFTP-only server that permits no command at all has no
    /// checksum capability either, and the honest way to say so is the same
    /// answer.
    private static func probe(
        over channel: some ChecksumCommandChannel, bounds: ChecksumBounds
    ) async -> Pass {
        for form in ChecksumCommandForm.allCases {
            let present = BoundedOutcome<Bool>()
            let finished = await BoundedClose.run(boundSeconds: bounds.probeSeconds) {
                let answer = try? await channel.standardOutput(of: form.presenceProbeLine())
                present.store(answer != nil)
            }
            guard finished else { return Pass(form: nil, conclusive: false) }
            if present.value == true { return Pass(form: form, conclusive: true) }
        }
        return Pass(form: nil, conclusive: true)
    }
}

/// The whole of "compute this file's checksum on the far side", above the
/// connection and therefore decidable without one.
///
/// It is the SSH backend's `RemoteChecksumProvider` body — the other three
/// backends answer without a command and never come through here;
/// `CitadelFileSystem` supplies the channel and the memory and adds nothing
/// of its own.
enum RemoteChecksumRun {
    static func checksum(
        forFileAt path: String,
        algorithm: ChecksumAlgorithm,
        over channel: some ChecksumCommandChannel,
        rememberedIn memory: ChecksumFormMemory,
        bounds: ChecksumBounds
    ) async throws -> RemoteChecksumOutcome {
        guard let form = await memory.form(over: channel, bounds: bounds) else {
            return .unavailableOnThisConnection
        }

        let outcome = BoundedOutcome<Result<String, Error>>()
        let finished = await BoundedClose.run(boundSeconds: bounds.runSeconds) {
            do {
                outcome.store(
                    .success(
                        try await channel.standardOutput(
                            of: form.commandLine(for: algorithm, path: path))))
            } catch {
                outcome.store(.failure(error))
            }
        }
        guard finished, let result = outcome.value else {
            throw RemoteFSError.protocolError(
                reason: "no checksum answer within \(bounds.runSeconds) s")
        }

        let output: String
        switch result {
        case .success(let text):
            output = text
        case .failure:
            // The far side's own words are not repeated here. They are input,
            // and this string is read by a log and by the App layer's error
            // mapping.
            throw RemoteFSError.protocolError(reason: "the checksum command failed on the far side")
        }

        guard let checksum = ChecksumOutputReader.read(output, algorithm: algorithm) else {
            throw RemoteFSError.protocolError(reason: "the checksum output could not be read")
        }
        return .checksum(checksum)
    }
}
