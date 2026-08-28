import Citadel
import Foundation

/// The project's only handle on an open Citadel SFTP session — and the
/// reason `try? await sftp.close()` is not an expression this module can
/// form.
///
/// This is a capability boundary in the sense of
/// `docs/superpowers/specs/2026-08-28-faehigkeitsgrenze-verbinden-design.md`:
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
/// And one thing it was never asked to cover: the `SFTPFile.close()` calls
/// in `CitadelFileSystem` are unbounded round trips of the same kind. They
/// are a recorded backlog observation, not a silent gap in this type —
/// counted and broken down in
/// `docs/superpowers/specs/2026-08-28-backlog-unbegrenzte-dateischluesse.md`.
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

    func openFile(filePath: String, flags: SFTPOpenFileFlags) async throws -> SFTPFile {
        try await raw.openFile(filePath: filePath, flags: flags)
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
