import Citadel
import Foundation
import NIOCore

/// The project's only handle on an open Citadel SFTP session — and the
/// reason `try? await sftp.close()` is not an expression this module can
/// form.
///
/// This is a capability boundary in the sense of
/// `docs/superpowers/specs/2026-08-28-capability-boundary-connect-design.md`:
/// not a better way to observe a mistake, but the withdrawal of the ability
/// to make it. `7ac7f7e` bounded the SFTP close because that call does not
/// return against a peer that has stopped answering (measured in
/// `.superpowers/sdd/frozen-peer-measurement.md`); nothing then stopped a
/// later edit from writing the unbounded call back, and a source-scanning
/// guard would have been the seventh in a row to lose to a new spelling.
/// So the raw `SFTPClient` stops being something the module holds:
/// `CitadelFileSystem` holds this type instead, `raw` is `private`, and the
/// only close reachable from anywhere else is `closeBounded()`.
///
/// The bound is a **property of this type, not an argument**. An earlier
/// draft took `closeBounded(boundSeconds:)`, which put a second copy of the
/// number at the call site — something a reader can get wrong, which is the
/// class of mistake this file exists to remove.
///
/// ## What this boundary does not prevent
///
/// Named here rather than in fine print, because a written promise larger
/// than the behaviour is how a guard earns unearned trust. All three were
/// executed against this very file, not assumed:
///
/// 1. **Deleting the close.** A `disconnect()` with no
///    `await sftp.closeBounded()` at all compiles. The child channel would
///    stay open until the parent close cascades to it — a different defect
///    from the one `7ac7f7e` fixed, and a visible deletion rather than a
///    silent revert. This type enforces *how* the stored session is closed,
///    never *that* it is.
/// 2. **Opening a fresh channel to close it.**
///    `try? await client.openSFTP().close()` compiles: it closes a brand-new
///    SFTP channel and leaves the stored session untouched. That is not the
///    old line coming back, it is a new and conspicuously different one —
///    and since `openSFTP()` is itself a round trip, it would reintroduce
///    the same hang against a frozen peer. What this type holds is the
///    stored client, not the door to Citadel.
/// 3. **Editing this file.** Whoever removes the bound here has removed it.
///    Exactly the honest limit the connect design records for
///    `.asking { _ in true }`: the difference is not impossibility but
///    **visibility** — the change stands at the definition, in a file named
///    after the guarantee, instead of at a call site a thousand lines away.
///
/// The one thing this type was never asked to cover — the `SFTPFile.close()`
/// calls in `CitadelFileSystem`, unbounded round trips of the same kind — is
/// now covered by `BoundedSFTPFile` below, for the same reason and by the
/// same move: `openFile` hands out that type instead of Citadel's, so the
/// unbounded file close is likewise not an expression this module can form.
/// What that measurement found is in
/// `docs/superpowers/specs/2026-08-28-backlog-unbounded-file-closes.md`.
/// The other call of that shape, `CitadelShell.close()`, is NOT among them:
/// it is unbounded in itself, but the App layer runs it inside
/// `TeardownStage.shutDownTerminal`'s bound, which is the stage bound that
/// measurement showed to be the one that actually fires.
///
/// The forwarding methods below cover exactly the operations this project
/// performs. They deliberately omit Citadel's defaulted `attributes:`
/// (`openFile`, `createDirectory`) and `flags:` (`rename`) parameters, so
/// that no default value is copied out of Citadel and kept in step by hand;
/// the first caller that needs one reopens that decision visibly, by adding
/// the parameter here.
final class BoundedSFTPSession: Sendable {
    private let raw: SFTPClient

    private init(raw: SFTPClient) {
        self.raw = raw
    }

    /// The one way to obtain a `BoundedSFTPSession`: open the SFTP child
    /// channel on an established SSH connection. Citadel schedules its
    /// uncancelled 15-second "no reply" timer on the connection's event loop
    /// the moment this is CALLED — see `CitadelFileSystem.disconnect()` for
    /// the citation and for what that costs at shutdown.
    static func open(on client: SSHClient) async throws -> BoundedSFTPSession {
        BoundedSFTPSession(raw: try await client.openSFTP())
    }

    /// How long `closeBounded()` waits for the SFTP child channel to close
    /// before abandoning that wait, so that its caller can close the parent
    /// connection(s) anyway.
    ///
    /// There has to be a bound at all because the underlying close does not
    /// return against a peer that has stopped answering. Measured, not
    /// assumed (`.superpowers/sdd/frozen-peer-measurement.md`): held directly
    /// against a `docker pause`d container, that one call sat inside a
    /// 20-second bound for 20.01678975 s, while `SSHClient.close()` on the
    /// same frozen peer returned in 0.051039125 s; driven through the real
    /// give-up path, `CitadelFileSystem.disconnect()` was entered and never
    /// left inside two independent bounds, 120 s and 30 s. `try?` swallows an
    /// error; it never bounded a wait. Thawing the peer released the
    /// abandoned call in 0.000568042 s, so the call is not slow — it is
    /// waiting for a reply that is not coming.
    ///
    /// Five seconds, argued from both directions:
    ///
    /// - Not less: a healthy `disconnect()` — all three closes, against the
    ///   Docker rig over loopback, with this bound in place — was measured
    ///   ten times in a row, slowest 0.001507583 s. Five seconds is more
    ///   than three thousand times that, which is the room a real link with
    ///   a real round-trip time needs and a loopback measurement cannot
    ///   show.
    /// - Not more: this bound is spent ON TOP of detection, which already
    ///   costs two probe deadlines (measured at 14.1–14.9 s). Five seconds
    ///   keeps a silently dropped connection under about twenty seconds from
    ///   silence to `.lost`, and stays well inside the 16 seconds the
    ///   detached event-loop-group shutdown in `disconnect()` waits out.
    ///
    /// Not `private`: `CitadelFileSystem.sftpCloseBoundSeconds` is an alias
    /// for this, and `LivenessProbeDropIntegrationTests` derives its own
    /// bound from that alias rather than spelling a second copy of the
    /// number beside it.
    static let closeBoundSeconds = 5

    /// Closes the stored SFTP session against `closeBoundSeconds`, and
    /// answers whether it finished inside that bound.
    ///
    /// Abandoning the call when the bound wins is the whole point (see
    /// `BoundedClose`): the caller gets to continue and close the parent
    /// connection, which is what actually ends the session. The `[raw]`
    /// capture hands a Citadel value to a task that may outlive this call;
    /// `CitadelFileSystem.disconnect()` carries the argument for why nothing
    /// races it there.
    @discardableResult
    func closeBounded() async -> Bool {
        await BoundedClose.run(boundSeconds: Self.closeBoundSeconds) { [raw] in
            try? await raw.close()
        }
    }

    func listDirectory(atPath path: String) async throws -> [SFTPMessage.Name] {
        try await raw.listDirectory(atPath: path)
    }

    func getAttributes(at filePath: String) async throws -> SFTPFileAttributes {
        try await raw.getAttributes(at: filePath)
    }

    /// Opens a file on this session and hands back the only file handle this
    /// module has — see `BoundedSFTPFile`. Citadel's `SFTPFile` does not
    /// leave this file.
    func openFile(filePath: String, flags: SFTPOpenFileFlags) async throws -> BoundedSFTPFile {
        BoundedSFTPFile(raw: try await raw.openFile(filePath: filePath, flags: flags))
    }

    func remove(at filePath: String) async throws {
        try await raw.remove(at: filePath)
    }

    func createDirectory(atPath path: String) async throws {
        try await raw.createDirectory(atPath: path)
    }

    func rmdir(at filePath: String) async throws {
        try await raw.rmdir(at: filePath)
    }

    func rename(at oldPath: String, to newPath: String) async throws {
        try await raw.rename(at: oldPath, to: newPath)
    }

    func setAttributes(at filePath: String, to attributes: SFTPFileAttributes) async throws {
        try await raw.setAttributes(at: filePath, to: attributes)
    }

    func getRealPath(atPath path: String) async throws -> String {
        try await raw.getRealPath(atPath: path)
    }
}

/// The project's only handle on an open Citadel SFTP FILE — and the reason
/// `try? await file.close()` is not an expression `CitadelFileSystem` can
/// form either.
///
/// One level down from `BoundedSFTPSession`, for the same reason and by the
/// same move. `7ac7f7e` bounded the session close and left the file closes
/// alone; they were then measured against a `docker pause`d peer and behave
/// exactly like the session close did — the numbers, the shape of the
/// measurement and what it did NOT establish are in
/// `docs/superpowers/specs/2026-08-28-backlog-unbounded-file-closes.md`
/// ("Measured 2026-09-02"), which is where they stay rather than being
/// copied here to drift.
///
/// Why the raw file must not escape: counted in this pass,
/// `CitadelFileSystem` closed a file at eight call sites — five directly on
/// the handle (three in `write`, one in `SFTPReadHandle.closeBounded`, one
/// in its `deinit`) and three through that box, in `readStream` — and a
/// bound written at each would be eight copies of one decision, any of which
/// a later edit could drop without anything failing.
/// Withdrawing the ability is the same trade the session type argues for at
/// length above — read its "What this boundary does not prevent" section
/// before trusting this one further than it goes, because all three limits
/// hold here unchanged: the close can be deleted, a second handle can be
/// opened to close, and whoever edits this file has edited it.
///
/// A `final class` rather than a `struct`, matching `BoundedSFTPSession`:
/// one open file on a server is an identity, not a value. A struct would be
/// copyable, and every copy would name the same server-side handle — while
/// `SFTPReadHandle` in `CitadelFileSystem` is documented as the SOLE owner
/// of one open file and binds its close to its own deallocation, which is a
/// claim about identity that only a reference type can carry.
///
/// `@unchecked Sendable`, where the session type gets `Sendable` for free:
/// Citadel's `SFTPClient` is `Sendable` and its `SFTPFile` is not. The
/// crossing is real and narrow — `closeBounded()` hands a value to a task
/// that may outlive the call, the same shape the session's does, but not
/// the same capture. The session's operation closure captures `[raw]`
/// directly: `SFTPClient` is `Sendable`, so naming it in a `@Sendable`
/// closure is legal on its own. `raw` here is `SFTPFile`, which is NOT
/// `Sendable` — the closure cannot name it directly, so it captures
/// `[self]` instead, which is legal only because this type carries the
/// `@unchecked Sendable` this paragraph is on. `[self]` does more than
/// satisfy the compiler: it is also what keeps `raw` alive for a close
/// that is still parked after the object that asked for it is gone — see
/// `SFTPReadHandle.deinit` below, where the box that requested this close
/// can deallocate while the close itself is still parked past the bound;
/// the operation closure's own reference to `self` is what the parked
/// task keeps running on once that box is gone. What makes it safe is
/// ownership, not luck: `openFile` returns a fresh handle per call, each
/// of this project's two callers (`readStream`, `write`) keeps its own
/// and never shares it, and the abandoned task's only remaining act is the
/// one close it was handed.
///
/// One pair of tasks that this change makes possible for the FIRST time, and
/// why it holds: a `closeBounded()` whose bound won leaves its operation task
/// parked inside Citadel's `sendRequest`, and the caller then drops the
/// stream — so `SFTPReadHandle.deinit` starts a SECOND close on the same
/// non-`Sendable` `SFTPFile` while the first is still suspended in it. Two
/// tasks, one object.
///
/// What keeps that safe here is a race that does not bite, not a guarantee
/// the type gives. `isActive` is Citadel's own `public private(set) var`
/// (`Citadel/Sources/Citadel/SFTP/Client/SFTPFile.swift:13`) — a plain
/// property, no lock, no actor isolation, nothing that puts a
/// synchronisation edge between one task's write to it and another task's
/// read. `close()` writes `isActive = false` BEFORE it sends anything
/// (`Citadel/Sources/Citadel/SFTP/Client/SFTPFile.swift:264`), and the
/// parked task performs that write, synchronously, before it ever suspends
/// at `sendRequest`. The second call can only be issued once
/// `SFTPReadHandle.deinit` runs, and in this exact scenario that cannot
/// happen before the caller drops the stream — which happens only after
/// `closeBounded()` has already returned, i.e. at least `closeBoundSeconds`
/// after the parked task's write. So the second call's
/// `guard self.isActive` sees `false` because that much has already
/// happened, in ordinary wall-clock and scheduling terms, by the time it
/// runs — not because anything here promises the write is visible.
/// Nothing forces that ordering to hold; it is a property of THIS call
/// shape (write, then a multi-second wait, then the second call), not of
/// the type. If it somehow did not hold, the second close would instead
/// send a real request over the same wire — and since it is itself a
/// `closeBounded()` against the same frozen peer, it would just also hit
/// `BoundedClose`'s bound and be abandoned the same way. Either outcome is
/// a second abandoned close, never a torn write or a skipped one.
final class BoundedSFTPFile: @unchecked Sendable {
    private let raw: SFTPFile

    /// `fileprivate`, so `BoundedSFTPSession.openFile` is the only way to
    /// get one: the point of the type is that a raw `SFTPFile` cannot be
    /// named outside this file, and a wrapper anyone could construct would
    /// need the raw value at its call site to do it.
    fileprivate init(raw: SFTPFile) {
        self.raw = raw
    }

    /// Closes this file against `BoundedSFTPSession.closeBoundSeconds`, and
    /// answers whether it finished inside that bound.
    ///
    /// The bound is that constant and not one of this type's own: it bounds
    /// the same round trip to the same peer, so a second number here would
    /// be a second copy of one decision — the mistake the session type's doc
    /// comment records rejecting for `closeBounded(boundSeconds:)`.
    ///
    /// `false` means the bound elapsed and the close was ABANDONED (see
    /// `BoundedClose`): the caller continues, and the handle stays open on
    /// the far side until the connection falls. That is the trade — one
    /// stranded server-side handle on a connection that has already stopped
    /// answering, against a transfer that never returns.
    ///
    /// Like the session's, this swallows the close's ERROR as well as its
    /// wait. A close that answers a non-`ok` status is reported as `true`
    /// here (it did return), which is a loss against the `try await
    /// file.close()` this replaced in `CitadelFileSystem.write`; see the
    /// comment at that call site for why the loss is accepted there.
    ///
    /// NOT `@discardableResult`, where `BoundedSFTPSession.closeBounded` is
    /// — the one place the two types part company, and for a reason that is
    /// about arithmetic rather than taste. The session's close has a single
    /// caller, `disconnect()`, whose handling of the answer is argued in
    /// twenty lines beside it. This one has eight, and an answer that eight
    /// sites may drop by saying nothing is an answer nobody decided about.
    /// `_ = await file.closeBounded()` costs two characters and makes each
    /// of those a visible choice.
    func closeBounded() async -> Bool {
        await BoundedClose.run(boundSeconds: BoundedSFTPSession.closeBoundSeconds) { [self] in
            try? await raw.close()
        }
    }

    func read(from offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try await raw.read(from: offset, length: length)
    }

    func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        try await raw.write(data, at: offset)
    }

    func readAttributes() async throws -> SFTPFileAttributes {
        try await raw.readAttributes()
    }
}
