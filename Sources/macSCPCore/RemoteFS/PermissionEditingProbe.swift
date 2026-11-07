import Foundation

/// Whether THIS CONNECTION will take a permission change — asked of the
/// connection, because for one protocol the answer is not a property of the
/// protocol.
///
/// A backend capability queried via `as?`, like `RemoteChecksumProvider` and
/// `PresignedURLProvider`. It exists for FTP and for the reason the FTP
/// design's §14 gives: `setPermissions` maps to `SITE CHMOD`, which is not in
/// RFC 959 at all — it is a per-server extension — so `.posixMode` is true of
/// the protocol and may be false of the server in front of you. The decision
/// recorded there is that "the permission editor is offered per connection
/// rather than per protocol, probed once like `ChecksumFormMemory.form` does
/// for checksums, so a server that refuses `SITE CHMOD` shows no editor
/// instead of an editor that always fails."
///
/// **It does not replace `ProtocolCapabilities.permissionModel`, and the two
/// say different things.** The capability is a statement about the protocol:
/// FTP has POSIX mode bits, S3 and WebDAV have none, and a backend whose
/// model is `.none` is not asked this question at all
/// (`PermissionsAvailability.isOffered(for:on:)` reads the capability first).
/// This is a statement about one server.
///
/// **A `false` here is NOT the same as a refusal, and the two must not be
/// merged.** The design's decision 10 says a refused `SITE CHMOD` on one file
/// is a per-file error and not a capability claim — the same distinction
/// `RemoteChecksumOutcome` draws between `unavailableOnThisConnection` and a
/// thrown `RemoteFSError`. So a server that HAS the extension and declines it
/// for a file the account does not own answers `true` here and throws on that
/// file, which is right: the editor exists and that one file cannot be
/// changed.
///
/// The three conformers a reader might expect and will not find: SSH, local
/// and WebDAV. SSH and local have a real `chmod` whose availability is the
/// protocol's, and WebDAV has no permission model to probe.
public protocol PermissionEditingProbe: Sendable {
    /// Whether this connection has a way to change permissions at all.
    ///
    /// Asked ONCE per connection and remembered, which is what makes it
    /// usable from a surface: a view that asks it per row would spend a round
    /// trip per row. It is `async` because the first ask may be that round
    /// trip.
    ///
    /// No `throws`: a probe that could not be completed is not a failure to
    /// report, it is an answer with less behind it. Which way an inconclusive
    /// probe falls is the conformer's decision and is argued where it is
    /// made.
    func offersPermissionEditing() async -> Bool
}
